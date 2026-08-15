import 'dart:math';

import '../config/app_config.dart';
import '../database/app_database.dart';
import '../../features/bible/data/bible_repository.dart';

/// Today's verse — fully local (PROJECT_MIGRATION_AUDIT.md Phase 4: "make
/// the workers actually run locally, not via a cloud round trip").
///
/// This is spec §27's DailyContentEngine exactly as described: "Date ->
/// stable seed -> verse selection -> daily verse. The same day should
/// produce the same verse for the user." A date-seeded pick doesn't need
/// a server to be consistent — every device computes the identical
/// result from the identical seed (today's date), so there's nothing to
/// synchronize and nothing that can be offline.
///
/// This used to write/read a Firestore doc per date so multiple devices
/// would agree on the day's verse. That coordination was never actually
/// necessary — a deterministic seed already guarantees agreement without
/// a shared write. Removing the Firestore round trip doesn't lose
/// anything the old version provided; it just stops paying a network
/// cost (and a "what if today's doc doesn't exist yet" race) for a
/// result that was always computable locally.
class VerseWorker {
  VerseWorker._internal();
  static final VerseWorker instance = VerseWorker._internal();

  /// Returns today's verse reference + text (English) for [language]'s
  /// display context. No network involved at all — this either succeeds
  /// instantly or, if English hasn't been Bible-imported on this device
  /// yet, returns the reference alone (still deterministic, just without
  /// pre-fetched text).
  Future<Map<String, dynamic>> getTodaysVerse(
      {required String language}) async {
    final reference = _referenceForDate(DateTime.now());

    try {
      final repo = BibleRepository(AppDatabaseService.instance.database);
      final verses = await repo.getPassage(reference, language: 'en');
      final text =
          verses.map((v) => v.text ?? '').where((t) => t.isNotEmpty).join(' ');
      return {
        'reference': reference,
        'text_en': text,
        'language': language,
        'source': 'deterministic',
      };
    } catch (_) {
      // English not imported yet, or the fallback reference somehow
      // doesn't resolve — the reference itself is still correct and
      // stable; just no pre-fetched text to show alongside it.
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
    return AppConfig
        .verseFallbackReferences[random.nextInt(AppConfig.verseFallbackReferences.length)];
  }

  String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
