import 'dart:math';

import '../config/app_config.dart';
import '../database/app_database.dart';
import '../../features/bible/data/bible_repository.dart';
import '../../features/bible/data/bible_providers.dart' show kAppLanguageToBibleCode;

/// Today's verse — fully local (PROJECT_MIGRATION_AUDIT.md Phase 4: "make
/// the workers actually run locally, not via a cloud round trip").
///
/// This is spec §27's DailyContentEngine exactly as described: "Date ->
/// stable seed -> verse selection -> daily verse. The same day should
/// produce the same verse for the user." A date-seeded pick doesn't need
/// a server to be consistent — every device computes the identical
/// result from the identical seed (today's date), so there's nothing to
/// synchronize and nothing that can be offline.
class VerseWorker {
  VerseWorker._internal();
  static final VerseWorker instance = VerseWorker._internal();

  /// Returns today's verse reference + text in [language]'s own Bible
  /// (not English regardless of [language] — that was a real bug: this
  /// used to hardcode `language: 'en'` when fetching passage text no
  /// matter what was actually requested, confirmed on a real device
  /// selecting Yoruba/Hausa/Igbo/Pidgin and still seeing English verse
  /// text). [language] is the app's own language key ('yoruba', 'hausa',
  /// etc, matching LanguageNotifier) — mapped to the Bible dataset's own
  /// short code via kAppLanguageToBibleCode.
  Future<Map<String, dynamic>> getTodaysVerse(
      {required String language}) async {
    final reference = _referenceForDate(DateTime.now());
    final bibleCode = kAppLanguageToBibleCode[language] ?? 'en';

    try {
      final repo = BibleRepository(AppDatabaseService.instance.database);
      final verses = await repo.getPassage(reference, language: bibleCode);
      final text = verses
          .map((v) => v.content ?? '')
          .where((t) => t.isNotEmpty)
          .join(' ');
      return {
        'reference': reference,
        'text': text,
        'language': language,
        'source': 'deterministic',
      };
    } catch (_) {
      // That language's Bible hasn't been imported into this device's
      // local database yet, or the fallback reference somehow doesn't
      // resolve — the reference itself is still correct and stable;
      // just no pre-fetched text to show alongside it. bible_screen.dart
      // now auto-imports on first open of a language rather than
      // gating behind a manual button, so this should self-resolve
      // shortly after a language is first used, not stay broken.
      return {
        'reference': reference,
        'language': language,
        'source': 'deterministic_reference_only',
      };
    }
  }

  /// Same seeded pick as [getTodaysVerse], exposed separately for callers
  /// (e.g. PrayerWorker) that only need the reference, not a Bible DB
  /// lookup.
  String todaysReference() => _referenceForDate(DateTime.now());

  String _referenceForDate(DateTime date) {
    final dateKey = _dateKey(date);
    final random = Random(dateKey.hashCode);
    return AppConfig.verseFallbackReferences[
        random.nextInt(AppConfig.verseFallbackReferences.length)];
  }

  String _dateKey(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
