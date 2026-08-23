import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../../core/database/app_database.dart';

/// Thrown for any import failure — malformed source, checksum mismatch, or
/// structurally incomplete data (missing books/chapters/verses). The
/// importer refuses to write partial/corrupt data rather than silently
/// importing an incomplete Bible.
class BibleImportException implements Exception {
  BibleImportException(this.message);
  final String message;
  @override
  String toString() => 'BibleImportException: $message';
}

class BibleImportResult {
  BibleImportResult({
    required this.language,
    required this.booksImported,
    required this.chaptersImported,
    required this.versesImported,
    required this.approximateVerses,
    required this.omittedVerses,
    required this.elapsed,
    required this.checksum,
  });

  final String language;
  final int booksImported;
  final int chaptersImported;
  final int versesImported;
  final int approximateVerses;
  final int omittedVerses;
  final Duration elapsed;
  final String checksum;
}

/// Imports one language's Bible dataset (assets/bible/<lang>.json, produced
/// by the offline build_bible.py pipeline from KJV JSON + read-aloud script
/// sources) into Drift (was Isar — PROJECT_MIGRATION_AUDIT.md Phase 1).
///
/// Source data note: for yo/ha/ig/pcm, the original files ship without verse
/// numbers (they're read-aloud recording scripts) but with one verse per
/// line — build_bible.py reconstructs verse numbers from line position,
/// cross-checked against KJV's per-chapter verse count. ~99.7% of chapters
/// match exactly. See BIBLE_IMPORT_NOTES.md for the full anomaly list.
/// None of that pipeline or the manifest/checksum verification changed —
/// only the destination store did.
class BibleImporter {
  BibleImporter(this.db);
  final AppDatabase db;

  static const _manifestAsset = 'assets/bible/manifest.json';

  Future<BibleImportResult> importLanguage(String language) async {
    final manifestRaw = await rootBundle.loadString(_manifestAsset);
    final manifest = json.decode(manifestRaw) as Map<String, dynamic>;
    final entry = manifest[language] as Map<String, dynamic>?;
    if (entry == null) {
      throw BibleImportException('No manifest entry for language "$language".');
    }

    final assetPath = entry['file'] as String;
    final expectedChecksum = entry['sha256'] as String;

    final bytes = await rootBundle.load(assetPath);
    final byteList = bytes.buffer.asUint8List();
    final actualChecksum = sha256.convert(byteList).toString();
    if (actualChecksum != expectedChecksum) {
      throw BibleImportException(
        'Checksum mismatch for "$language": expected $expectedChecksum, got $actualChecksum. '
        'Refusing to import. The bundled asset may be corrupt or out of date with manifest.json.',
      );
    }

    late Map<String, dynamic> data;
    try {
      data = json.decode(utf8.decode(byteList)) as Map<String, dynamic>;
    } catch (e) {
      throw BibleImportException('Malformed JSON for "$language": $e');
    }

    final books = data['books'] as List<dynamic>? ?? [];
    if (books.length != 66) {
      throw BibleImportException(
        'Expected 66 books for "$language", found ${books.length}. Refusing partial import.',
      );
    }

    final sw = Stopwatch()..start();
    var bookCount = 0,
        chapterCount = 0,
        verseCount = 0,
        approxCount = 0,
        omittedCount = 0;

    await db.transaction(() async {
      // Re-imports replace the previous copy of this language cleanly —
      // no duplicate rows if the user re-runs import. Same semantics as
      // the Isar version's deleteAll-then-repopulate.
      await (db.delete(db.bibleBooks)
            ..where((t) => t.language.equals(language)))
          .go();
      await (db.delete(db.bibleChapters)
            ..where((t) => t.language.equals(language)))
          .go();
      await (db.delete(db.bibleVerses)
            ..where((t) => t.language.equals(language)))
          .go();

      final bookRows = <BibleBooksCompanion>[];
      final chapterRows = <BibleChaptersCompanion>[];
      final verseRows = <BibleVersesCompanion>[];

      for (final rawBook in books) {
        final book = rawBook as Map<String, dynamic>;
        final code = book['code'] as String;
        final chapters = book['chapters'] as List<dynamic>? ?? [];
        if (chapters.isEmpty) {
          throw BibleImportException(
              'Book $code has zero chapters in "$language". Aborting import.');
        }

        bookRows.add(BibleBooksCompanion.insert(
          language: language,
          code: code,
          name: book['name'] as String,
          testament: book['testament'] as String,
          position: book['position'] as int,
          chapterCount: chapters.length,
        ));
        bookCount++;

        for (final rawChapter in chapters) {
          final chapter = rawChapter as Map<String, dynamic>;
          final chapterNumber = chapter['number'] as int;
          final verses = chapter['verses'] as List<dynamic>? ?? [];
          if (verses.isEmpty) {
            throw BibleImportException(
              '$code chapter $chapterNumber has zero verses in "$language". Aborting import.',
            );
          }

          chapterRows.add(BibleChaptersCompanion.insert(
            language: language,
            bookCode: code,
            number: chapterNumber,
            verseCount: verses.length,
            localTitle: Value(chapter['localTitle'] as String?),
          ));
          chapterCount++;

          for (final rawVerse in verses) {
            final verse = rawVerse as Map<String, dynamic>;
            final text = verse['text'] as String?;
            final isOmitted = verse['omitted'] == true;
            final isApprox = verse['approximate'] == true;
            if (isOmitted) omittedCount++;
            if (isApprox) approxCount++;

            verseRows.add(BibleVersesCompanion.insert(
              language: language,
              bookCode: code,
              chapter: chapterNumber,
              number: verse['number'] as int,
              content: Value(text),
              omitted: Value(isOmitted),
              approximate: Value(isApprox),
              normalizedText: Value(_normalize(text)),
            ));
            verseCount++;
          }
        }
      }

      // Batched inserts instead of one write per row — this is ~31k verse
      // rows per language; per-row awaits here would be needlessly slow
      // compared to Isar's put() inside a single writeTxn, which batched
      // internally. batch() is Drift's equivalent.
      await db.batch((b) {
        b.insertAll(db.bibleBooks, bookRows);
        b.insertAll(db.bibleChapters, chapterRows);
        b.insertAll(db.bibleVerses, verseRows);
      });

      await db.into(db.bibleImportRecords).insertOnConflictUpdate(
            BibleImportRecordsCompanion.insert(
              language: language,
              checksum: actualChecksum,
              booksImported: bookCount,
              chaptersImported: chapterCount,
              versesImported: verseCount,
              approximateVerseCount: approxCount,
              omittedVerseCount: omittedCount,
              importedAt: DateTime.now(),
            ),
          );
    });

    sw.stop();
    return BibleImportResult(
      language: language,
      booksImported: bookCount,
      chaptersImported: chapterCount,
      versesImported: verseCount,
      approximateVerses: approxCount,
      omittedVerses: omittedCount,
      elapsed: sw.elapsed,
      checksum: actualChecksum,
    );
  }

  Future<bool> isImported(String language) async {
    final record = await (db.select(db.bibleImportRecords)
          ..where((t) => t.language.equals(language)))
        .getSingleOrNull();
    return record != null && record.booksImported == 66;
  }

  static String _normalize(String? text) {
    if (text == null) return '';
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '');
  }
}
