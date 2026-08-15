import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/bible_books.dart';

/// Thrown when a "Book Chapter:Verse"-style reference can't be parsed or
/// doesn't resolve to an imported book/chapter/verse.
class BibleReferenceException implements Exception {
  BibleReferenceException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ParsedReference {
  ParsedReference(
      {required this.book,
      required this.chapter,
      this.startVerse,
      this.endVerse});
  final CanonicalBook book;
  final int chapter;
  final int? startVerse;
  final int? endVerse;
}

/// Parses "John 3:16", "John 3:16-18", "1 Samuel 17", "Psalms 23:1" into a
/// [ParsedReference]. Pure text parsing — no I/O, unchanged from the Isar
/// version since it never touched the database.
ParsedReference parseBibleReference(String raw) {
  final input = raw.trim();
  final match =
      RegExp(r'^(.+?)\s+(\d+)(?::(\d+)(?:-(\d+))?)?$').firstMatch(input);
  if (match == null) {
    throw BibleReferenceException(
        'Could not parse reference "$raw". Try "John 3:16" or "Psalms 23".');
  }
  final bookName = match.group(1)!;
  final chapter = int.parse(match.group(2)!);
  final startVerse = match.group(3) != null ? int.parse(match.group(3)!) : null;
  final endVerse =
      match.group(4) != null ? int.parse(match.group(4)!) : startVerse;

  final book = findCanonicalBookByName(bookName);
  if (book == null) {
    throw BibleReferenceException(
        'Unknown book "$bookName" in reference "$raw".');
  }
  return ParsedReference(
      book: book, chapter: chapter, startVerse: startVerse, endVerse: endVerse);
}

/// Drift-backed replacement for the old Isar-backed BibleRepository.
/// Method names/shapes kept identical to the Isar version so callers
/// (bible_providers.dart, search_screen.dart, verse_worker.dart) need a
/// minimal diff — the return types change from `BibleXEntity` (Isar) to
/// Drift's generated row classes (`BibleBook`, `BibleChapter`,
/// `BibleVerse`), which is a straight rename at call sites since the field
/// names are identical.
class BibleRepository {
  BibleRepository(this.db);
  final AppDatabase db;

  Future<List<BibleBook>> getBooks(String language) {
    return (db.select(db.bibleBooks)
          ..where((t) => t.language.equals(language))
          ..orderBy([(t) => OrderingTerm.asc(t.position)]))
        .get();
  }

  Future<BibleChapter?> getChapter(
      String language, String bookCode, int chapterNumber) {
    return (db.select(db.bibleChapters)
          ..where((t) =>
              t.language.equals(language) &
              t.bookCode.equals(bookCode) &
              t.number.equals(chapterNumber)))
        .getSingleOrNull();
  }

  Future<List<BibleVerse>> getVerses(
    String language,
    String bookCode,
    int chapterNumber, {
    int? startVerse,
    int? endVerse,
  }) {
    final query = db.select(db.bibleVerses)
      ..where((t) =>
          t.language.equals(language) &
          t.bookCode.equals(bookCode) &
          t.chapter.equals(chapterNumber));
    if (startVerse != null) {
      final end = endVerse ?? startVerse;
      query.where((t) => t.number.isBetweenValues(startVerse, end));
    }
    query.orderBy([(t) => OrderingTerm.asc(t.number)]);
    return query.get();
  }

  /// Resolves a "Book Chapter:Verse[-Verse]" reference to verse rows for
  /// [language]. Throws [BibleReferenceException] if unparseable, or if the
  /// language hasn't been imported / the reference is out of range.
  Future<List<BibleVerse>> getPassage(String reference,
      {required String language}) async {
    final parsed = parseBibleReference(reference);
    final verses = await getVerses(
      language,
      parsed.book.code,
      parsed.chapter,
      startVerse: parsed.startVerse,
      endVerse: parsed.endVerse,
    );
    if (verses.isEmpty) {
      throw BibleReferenceException(
        '"$reference" not found in language "$language" — is this language imported, '
        'and does ${parsed.book.englishName} ${parsed.chapter} exist?',
      );
    }
    return verses;
  }

  /// Full-text substring search over normalized verse text. Offline, no API.
  /// Uses SQL LIKE against the same pre-normalized `normalizedText` column
  /// the Isar version indexed — normalization still happens once at import
  /// time (BibleImporter/BibleNormalizer), not here, so this is a straight
  /// SQL translation of the old `.normalizedTextContains(...)` filter, not
  /// a behavior change. For real FTS5 performance on low-end devices this
  /// should move to a Drift virtual FTS5 table in a follow-up pass — noted,
  /// not done here, since it's a schema change beyond a 1:1 port.
  Future<List<BibleVerse>> search(String language, String query,
      {int limit = 50}) {
    final normalized = query
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '')
        .trim();
    if (normalized.isEmpty) return Future.value(const []);
    return (db.select(db.bibleVerses)
          ..where((t) =>
              t.language.equals(language) &
              t.normalizedText.contains(normalized))
          ..limit(limit))
        .get();
  }

  Future<bool> isLanguageImported(String language) async {
    final count = await (db.selectOnly(db.bibleBooks)
          ..addColumns([db.bibleBooks.id.count()])
          ..where(db.bibleBooks.language.equals(language)))
        .map((row) => row.read(db.bibleBooks.id.count()) ?? 0)
        .getSingle();
    return count >= 66;
  }

  Future<BibleImportRecord?> importRecord(String language) {
    return (db.select(db.bibleImportRecords)
          ..where((t) => t.language.equals(language)))
        .getSingleOrNull();
  }
}
