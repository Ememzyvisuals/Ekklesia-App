import 'package:shared_preferences/shared_preferences.dart';

import 'groq_service.dart';
import 'verse_worker.dart';

/// Today's prayer — local-first (PROJECT_MIGRATION_AUDIT.md Phase 4).
/// Per spec §27: "Daily prayer can be prepackaged local content or
/// generated using Groq when available. Never make the entire home
/// screen dependent on Groq." Groq is genuinely one of the app's two
/// legitimate online-by-design features (the other is YouTube), so
/// keeping the optional Groq call here is correct — what's gone is the
/// Firestore round trip this used to make on top of it.
///
/// Unlike the verse (a deterministic pick, so every device already
/// agrees without coordination), a Groq-generated prayer is NOT
/// deterministic — asking Groq the same prompt twice gives different
/// wording. The old Firestore doc-per-date existed to make every device
/// share one wording. That's a "would be nice" property, not a
/// requirement — devices showing their own independently-generated (but
/// thematically identical, same verse-based prompt) prayer text is a
/// perfectly reasonable trade for not needing a server round trip at
/// all. Cached locally per-date so it's only generated once per device
/// per day, same as before — just no longer shared *across* devices.
class PrayerWorker {
  PrayerWorker._internal();
  static final PrayerWorker instance = PrayerWorker._internal();

  static const _cacheKey = 'cached_daily_prayer';
  static const _cacheDateKey = 'cached_daily_prayer_date';

  static const _offlineFallback =
      'Lord, thank You for this day. Guide my steps, renew my strength, '
      'and help me walk in Your word. Amen.';

  Future<Map<String, dynamic>> getTodaysPrayer(
      {required String language}) async {
    final today = _todayKey();
    final prefs = await SharedPreferences.getInstance();

    if (prefs.getString(_cacheDateKey) == today) {
      final cached = prefs.getString(_cacheKey);
      if (cached != null) {
        return {'text': cached, 'source': 'cache'};
      }
    }

    return _generateAndCache(today, language, prefs);
  }

  Future<Map<String, dynamic>> _generateAndCache(
      String dateKey, String language, SharedPreferences prefs) async {
    final reference = VerseWorker.instance.todaysReference();

    String text;
    String source;
    try {
      text = await GroqService.instance.chat([
        const GroqMessage(
          role: 'system',
          content: 'You write short, warm, biblically grounded daily prayers '
              '(4-6 sentences) for a Christian devotional app. Base the '
              'prayer thematically on the given verse reference without '
              'quoting long passages of scripture. Plain text only, no '
              'markdown, no preamble like "Here is a prayer".',
        ),
        GroqMessage(
            role: 'user',
            content: 'Write today\'s prayer based on $reference.'),
      ]);
      source = 'generated';
    } catch (_) {
      // No Groq key configured, offline, or the shared proxy's daily cap
      // was hit — falls back to a reference-aware canned prayer rather
      // than leaving the home screen's prayer card empty. This IS the
      // "app must remain useful without Groq" behavior spec §31 asks
      // for, not an error state.
      text = 'Lord, as we reflect on $reference today, help us live it out '
          'in how we treat others, and give us peace for whatever this day '
          'holds. Amen.';
      source = 'offline_fallback';
    }

    await prefs.setString(_cacheKey, text);
    await prefs.setString(_cacheDateKey, dateKey);
    return {'text': text, 'based_on_reference': reference, 'source': source};
  }

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }
}
