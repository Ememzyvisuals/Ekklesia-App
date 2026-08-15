import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';

/// Drift-backed replacement for the old Isar-backed
/// BibleAnnotationsRepository. Highlights/notes each still enforce "at
/// most one row per verse" the same way the Isar version did — via the
/// table's uniqueKeys constraint (see app_database.dart) plus an
/// insertOnConflictUpdate, rather than a manual find-then-delete-then-put
/// round trip. Behavior is identical; the upsert is just native to Drift.
class BibleAnnotationsRepository {
  BibleAnnotationsRepository(this.db);
  final AppDatabase db;

  // ---- Highlights ----

  Future<Map<int, Highlight>> getHighlightsForChapter(
    String language,
    String bookCode,
    int chapter,
  ) async {
    final rows = await (db.select(db.highlights)
          ..where((t) =>
              t.language.equals(language) &
              t.bookCode.equals(bookCode) &
              t.chapter.equals(chapter)))
        .get();
    return {for (final r in rows) r.verseNumber: r};
  }

  Future<void> setHighlight({
    required String language,
    required String bookCode,
    required int chapter,
    required int verseNumber,
    required String colorHex,
  }) {
    return db.into(db.highlights).insertOnConflictUpdate(
          HighlightsCompanion.insert(
            language: language,
            bookCode: bookCode,
            chapter: chapter,
            verseNumber: verseNumber,
            colorHex: colorHex,
            createdAt: DateTime.now(),
          ),
        );
  }

  Future<void> removeHighlight({
    required String language,
    required String bookCode,
    required int chapter,
    required int verseNumber,
  }) {
    return (db.delete(db.highlights)
          ..where((t) =>
              t.language.equals(language) &
              t.bookCode.equals(bookCode) &
              t.chapter.equals(chapter) &
              t.verseNumber.equals(verseNumber)))
        .go();
  }

  // ---- Notes ----

  Future<Note?> getNote({
    required String language,
    required String bookCode,
    required int chapter,
    required int verseNumber,
  }) {
    return (db.select(db.notes)
          ..where((t) =>
              t.language.equals(language) &
              t.bookCode.equals(bookCode) &
              t.chapter.equals(chapter) &
              t.verseNumber.equals(verseNumber)))
        .getSingleOrNull();
  }

  Future<void> setNote({
    required String language,
    required String bookCode,
    required int chapter,
    required int verseNumber,
    required String text,
  }) async {
    if (text.trim().isEmpty) {
      // empty text = delete, don't store a blank note — same rule as the
      // Isar version.
      await (db.delete(db.notes)
            ..where((t) =>
                t.language.equals(language) &
                t.bookCode.equals(bookCode) &
                t.chapter.equals(chapter) &
                t.verseNumber.equals(verseNumber)))
          .go();
      return;
    }
    await db.into(db.notes).insertOnConflictUpdate(
          NotesCompanion.insert(
            language: language,
            bookCode: bookCode,
            chapter: chapter,
            verseNumber: verseNumber,
            content: text.trim(),
            updatedAt: DateTime.now(),
          ),
        );
  }

  // ---- Reading progress / Continue Reading ----

  Future<ReadingProgressData?> getProgress(String language) {
    return (db.select(db.readingProgress)
          ..where((t) => t.language.equals(language)))
        .getSingleOrNull();
  }

  Future<void> saveProgress({
    required String language,
    required String bookCode,
    required String bookName,
    required int chapter,
  }) {
    return db.into(db.readingProgress).insertOnConflictUpdate(
          ReadingProgressCompanion.insert(
            language: language,
            bookCode: bookCode,
            bookName: bookName,
            chapter: chapter,
            updatedAt: DateTime.now(),
          ),
        );
  }

  // ---- Reading streak ----
  //
  // Single global row, same as the Isar version (isar.bibleReadingStreakEntitys.where().findFirst()).
  // Uses a fixed id=1 sentinel row rather than Isar's "whatever the first
  // row happens to be" — equivalent behavior, more explicit storage.

  static int _dayNumber(DateTime dt) =>
      DateTime(dt.year, dt.month, dt.day).difference(DateTime(1970)).inDays;

  Future<ReadingStreakData> getStreak() async {
    final existing = await (db.select(db.readingStreak)
          ..where((t) => t.id.equals(1)))
        .getSingleOrNull();
    return existing ??
        const ReadingStreakData(
          id: 1,
          currentStreak: 0,
          longestStreak: 0,
          totalDaysRead: 0,
          lastReadDay: 0,
        );
  }

  /// Call once whenever a chapter is opened (any language). No-ops if
  /// today has already been recorded — reading five chapters in one day
  /// only counts as one streak day, same as any habit tracker.
  Future<ReadingStreakData> recordReadingActivity() async {
    final today = _dayNumber(DateTime.now());
    final streak = await getStreak();

    if (streak.lastReadDay == today) {
      return streak; // already recorded today — no change
    }

    final wasConsecutive = streak.lastReadDay == today - 1;
    final newCurrent = wasConsecutive ? streak.currentStreak + 1 : 1;
    final updated = ReadingStreakData(
      id: 1,
      currentStreak: newCurrent,
      longestStreak:
          newCurrent > streak.longestStreak ? newCurrent : streak.longestStreak,
      totalDaysRead: streak.totalDaysRead + 1,
      lastReadDay: today,
    );

    await db.into(db.readingStreak).insertOnConflictUpdate(
          ReadingStreakCompanion.insert(
            id: const Value(1),
            currentStreak: Value(updated.currentStreak),
            longestStreak: Value(updated.longestStreak),
            totalDaysRead: Value(updated.totalDaysRead),
            lastReadDay: Value(updated.lastReadDay),
          ),
        );
    return updated;
  }
}
