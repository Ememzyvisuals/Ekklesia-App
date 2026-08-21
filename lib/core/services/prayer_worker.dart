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

  Future<Map<String, dynamic>> getTodaysPrayer(
      {required String language}) async {
    final today = _todayKey();
    // Cache key now includes language — without this, switching
    // language mid-day would still serve whatever language generated
    // the first cache hit that day, since only the date was ever
    // checked before.
    final cacheKey = '${_cacheKey}_$language';
    final prefs = await SharedPreferences.getInstance();

    if (prefs.getString(_cacheDateKey) == today) {
      final cached = prefs.getString(cacheKey);
      if (cached != null) {
        return {'text': cached, 'source': 'cache'};
      }
    }

    return _generateAndCache(today, language, prefs, cacheKey);
  }

  Future<Map<String, dynamic>> _generateAndCache(String dateKey,
      String language, SharedPreferences prefs, String cacheKey) async {
    final reference = VerseWorker.instance.todaysReference();

    // Was previously ignored entirely — `language` was accepted as a
    // parameter but never referenced anywhere below, so the Groq prompt
    // was always plain English text regardless of what was actually
    // selected. Confirmed on a real device: switching to Yoruba/Hausa/
    // Igbo/Pidgin still produced an English prayer every time.
    final languageName = switch (language) {
      'yoruba' => 'Yoruba',
      'hausa' => 'Hausa',
      'igbo' => 'Igbo',
      'pidgin' => 'Nigerian Pidgin English',
      _ => 'English',
    };

    String text;
    String source;
    try {
      text = await GroqService.instance.chat([
        GroqMessage(
          role: 'system',
          content: 'You write short, warm, biblically grounded daily '
              'prayers (4-6 sentences) for a Christian devotional app. '
              'Base the prayer thematically on the given verse reference '
              'without quoting long passages of scripture. Write entirely '
              'in $languageName. Plain text only, no markdown, no '
              'preamble like "Here is a prayer".',
        ),
        GroqMessage(
            role: 'user',
            content: 'Write today\'s prayer based on $reference.'),
      ]);
      source = 'generated';
    } catch (_) {
      // Was a single hardcoded English string, always — if Groq fails
      // consistently for someone (no key set, shared proxy rate-limited,
      // offline), this is the ONLY prayer text they would ever see, in
      // any language, which is exactly "it's always the same thing"
      // reported on a real device. Now: several templates per language,
      // chosen deterministically from the date + language (so it's
      // still one consistent prayer per day, not different every time
      // the card is reopened, but no longer identical day after day),
      // and actually translated rather than English-only regardless of
      // the selected language. These are functional but simple
      // translations — worth a native-speaker review pass, same caveat
      // as the companion accessibility labels.
      final templates =
          _fallbackTemplates[language] ?? _fallbackTemplates['english']!;
      final index = (dateKey + language).hashCode.abs() % templates.length;
      text = templates[index](reference);
      source = 'offline_fallback';
    }

    await prefs.setString(cacheKey, text);
    await prefs.setString(_cacheDateKey, dateKey);
    return {'text': text, 'based_on_reference': reference, 'source': source};
  }

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  /// Fallback-only prayer templates, several per language, picked
  /// deterministically per day+language (see the catch block above) —
  /// only ever used when Groq generation actually fails. When Groq
  /// succeeds, the prayer is freshly generated every day regardless.
  static final Map<String, List<String Function(String)>> _fallbackTemplates = {
    'english': [
      (ref) => 'Lord, as we reflect on $ref today, help us live it out in '
          'how we treat others, and give us peace for whatever this day '
          'holds. Amen.',
      (ref) => 'Father, thank You for Your word in $ref. Give us the '
          'strength to carry it into today, and a heart that stays open '
          'to Your leading. Amen.',
      (ref) => 'Lord, let $ref shape the way we think and act today. '
          'Guard our hearts, steady our steps, and remind us that You are '
          'near. Amen.',
      (ref) => 'God, we bring today to You in light of $ref. Where we are '
          'weary, renew us; where we are unsure, guide us. Amen.',
    ],
    'yoruba': [
      (ref) => 'Oluwa, bi a se n ronu nipa $ref loni, ran wa lowo lati '
          'gbe e ni ise, ki o si fun wa ni alafia fun ohunkohun ti ojo yi '
          'mu wa. Amin.',
      (ref) => 'Baba, a dupe fun ọrọ Rẹ ninu $ref. Fun wa ni agbara lati gbe '
          'e loni, ati okan ti o si sile fun itọsọna Rẹ. Amin.',
    ],
    'hausa': [
      (ref) => 'Ubangiji, yayin da muke tunani a kan $ref yau, ka taimake '
          'mu mu rayu da shi, ka kuma ba mu salama don duk abin da wannan '
          'rana ta kawo. Amin.',
      (ref) => 'Uba, muna godiya don maganarka a cikin $ref. Ka ba mu karfi '
          'mu dauke shi cikin yau, da zuciyar da ke bude ga jagorancinka. '
          'Amin.',
    ],
    'igbo': [
      (ref) => 'Onyenwe anyị, ka anyị na-atule $ref taa, nyere anyị aka '
          'ibi ya na ndụ anyị, nyekwa anyị udo maka ihe ọ bụla ụbọchị a '
          'na-eweta. Amen.',
      (ref) => 'Nna, anyị na-ekele gị maka okwu gị dị na $ref. Nye anyị ike '
          'iburu ya n\'ime taa, na obi meghere maka nduzi gị. Amen.',
    ],
    'pidgin': [
      (ref) => 'Lord, as we dey think about $ref today, help us to live '
          'am out for how we dey treat other people, and give us peace '
          'for whatever this day carry. Amen.',
      (ref) => 'Father, thank You for Your word for $ref. Give us strength '
          'to carry am go today, and heart wey go dey open for Your '
          'guidance. Amen.',
    ],
  };
}
