/// Central place for external endpoints and non-secret config.
///
/// Actual API keys (Groq, YouTube Data API, HF tokens if ever needed
/// client-side) must NOT live here — pull them from a secure source
/// (e.g. a backend proxy or Firebase Remote Config + App Check), never
/// hardcoded into the shipped app.
class AppConfig {
  AppConfig._();

  /// A visible marker so the person testing a build and the developer
  /// diagnosing it can both immediately confirm they're looking at the
  /// same code, without relying on "did you rebuild?" back-and-forth —
  /// added specifically because several rounds of fixes for the exact
  /// same TTS/Radio `LateInitializationError` kept coming back with
  /// literally identical error text, and there was no fast, certain way
  /// to tell whether that meant a fix genuinely didn't work or whether
  /// an old APK was still what got tested. Bump this string every time a
  /// new batch of fixes ships. Shown in Settings and appended to every
  /// "Error details" dialog across the app.
  static const String buildTag = 'batch10-2026-08-28';

  // wazobiaVoiceSpaceUrl/yarnGptSpaceUrl removed (PROJECT_MIGRATION_AUDIT.md
  // Phase 5) — TTS is fully on-device now (sherpa_onnx + MMS models,
  // system TTS for English). No cloud TTS engine remains in this app.

  // DCLM radio direct stream mounts — LibreTime/Airtime harbor port 8xxx per
  // language. All four (including English) confirmed live via the
  // WazobiaVoice_TTS_Scraper ffprobe test, not just page-scrape inference.
  /// Verified against DCLM's own official radio-app-v1 source (each
  /// language's .php page, e.g. yoruba.php / hausa.php / index.php for
  /// English) — not guessed or reused from a stale doc. This fixes a real
  /// bug: 'english' previously pointed at 8050/english, which is actually
  /// French's mount (8050/french, confirmed in french.php); English is
  /// 8000/live. Every other entry below matched what was already here.
  static const Map<String, String> dclmStreams = {
    'yoruba': 'https://airtime.dclm.org/radio/8060/yoruba',
    'hausa': 'https://airtime.dclm.org/radio/8070/hausa',
    'igbo': 'https://airtime.dclm.org/radio/8090/igbo',
    'english': 'https://airtime.dclm.org/radio/8000/live',
  };

  /// Additional official DCLM language streams beyond the 4 currently
  /// selectable in live_screen.dart's picker — captured here since
  /// they're verified and real, not because anything reads them yet.
  /// Wiring more languages into the picker is a UI decision for later,
  /// not assumed here. No Nigerian Pidgin stream exists on DCLM's
  /// platform (checked directly) — unrelated to the Bible feature, which
  /// *does* have a Nigerian Pidgin translation now via the offline
  /// import pipeline (see features/bible/data/bible_importer.dart).
  static const Map<String, String> dclmExtraStreams = {
    'french': 'https://airtime.dclm.org/radio/8050/french',
    'portuguese': 'https://airtime.dclm.org/radio/8110/portuguese',
    'spanish': 'https://airtime.dclm.org/radio/8100/spanish',
    'egun': 'https://airtime.dclm.org/radio/8120/egun',
    'ebira': 'https://airtime.dclm.org/radio/8125/ebira',
    'twi': 'https://airtime.dclm.org/radio/8135/twi',
    'ewe': 'https://airtime.dclm.org/radio/8140/ewe',
    'efik': 'https://airtime.dclm.org/radio/8145/efik',
    'igede': 'https://airtime.dclm.org/radio/8230/igede',
    'idoma': 'https://airtime.dclm.org/radio/8220/idoma',
    'tiv': 'https://airtime.dclm.org/radio/8240/tiv',
    'gbagyi': 'https://airtime.dclm.org/radio/8250/gbagyi',
    'igala': 'https://airtime.dclm.org/radio/8040/igala',
    // Urhobo is served from a different platform (AzuraCast, not the
    // Icecast/Airtime mounts above) per urhobo.php — different host,
    // included as-is rather than normalized to a fake matching pattern.
    'urhobo': 'https://studio.dclm.org/listen/urhobo/urhobo',
  };

  /// stat1.dclm.org's Now Playing API (AzuraCast), keyed the same as
  /// [dclmStreams] + [dclmExtraStreams] — one query gives
  /// now_playing.song.{artist,title,art} and listeners.current. Verified
  /// per-language station ids straight from each language page's own
  /// script block (e.g. nowplaying/1 for English, /2 for Yoruba, etc.).
  /// The official radio-app-v1 site polls this every 60s; RadioService
  /// mirrors that cadence rather than polling faster.
  ///
  /// Discovered inconsistency in DCLM's own source, not introduced here:
  /// tiv.php and gbagyi.php both fetch nowplaying/16 verbatim — that's
  /// either a real shared station or a copy-paste bug on DCLM's end.
  /// Left as-is (matching the official site) rather than guessing a
  /// "corrected" id with no way to verify one against the live API from
  /// here.
  static const Map<String, int> dclmNowPlayingStationIds = {
    'english': 1,
    'yoruba': 2,
    'french': 3,
    'hausa': 4,
    'igbo': 5,
    'portuguese': 6,
    'egun': 7,
    'spanish': 8,
    'ebira': 9,
    'efik': 10,
    'ewe': 11,
    'twi': 12,
    'urhobo': 13,
    'igede': 14,
    'idoma': 15,
    'gbagyi': 16,
    'tiv': 17,
    'igala': 18,
  };

  static const String dclmNowPlayingBaseUrl =
      'https://stat1.dclm.org/api/nowplaying';

  /// Single source of truth for radio language display names — used by
  /// live_screen.dart's language picker. Covers all 18 verified DCLM
  /// language streams ([dclmStreams] + [dclmExtraStreams]), not just the
  /// 4 that used to be wired into the picker.
  static const Map<String, String> dclmLanguageLabels = {
    'english': 'English',
    'yoruba': 'Yoruba',
    'hausa': 'Hausa',
    'igbo': 'Igbo',
    'french': 'French',
    'portuguese': 'Portuguese',
    'spanish': 'Spanish',
    'egun': 'Egun',
    'ebira': 'Ebira',
    'twi': 'Twi',
    'ewe': 'Ewe',
    'efik': 'Efik',
    'igede': 'Igede',
    'idoma': 'Idoma',
    'tiv': 'Tiv',
    'gbagyi': 'Gbagyi',
    'igala': 'Igala',
    'urhobo': 'Urhobo',
  };

  static const Map<String, String> dclmPageFallback = {
    'yoruba': 'https://radio.dclm.org/yoruba',
    'hausa': 'https://radio.dclm.org/hausa',
    'igbo': 'https://radio.dclm.org/igbo',
    'english': 'https://radio.dclm.org/english',
  };

  // ---- Bible text sources ----
  // The wldeh CDN Bible API is no longer used client-side — the offline
  // Bible engine (features/bible/) reads from a local Isar database
  // populated from assets/bible/*.json via BibleImporter. Datasets are
  // keyed by short code ('en', 'yo', 'ha', 'ig', 'pcm') via
  // bible_providers.dart's kAppLanguageToBibleCode / kBibleCodeLabel maps.
  // Nigerian Pidgin DOES have a Bible-reading tab now (assets/bible/pcm.json,
  // ~31k verses) — an earlier comment here claiming no Pidgin translation
  // exists predates the read-aloud-script data this was built from.

  // Groq — chat, summaries, quiz generation. No Cloudflare Worker, no
  // shared key at all: every user supplies their own Groq API key (see
  // UserGroqKeyService/GroqService), and GroqService/AIConfig call
  // Groq's API directly with it. `cloudflare/groq-proxy/` and its
  // device-token auth were deleted entirely — by explicit instruction,
  // this app runs no cloud infrastructure of its own.

  // youtubeSyncProxyBaseUrl removed (PROJECT_MIGRATION_AUDIT.md Phase 3)
  // — the client calls the YouTube Data API directly (see youtubeApiKey
  // below). The `cloudflare/youtube-sync/` Worker this replaced has
  // since been deleted outright too — no cloud infrastructure of any
  // kind remains in this app.

  // Model fallback chain (per user decision): 70B primary for response
  // quality, 8B-instant as the fallback if 70B is ever deprecated/
  // unavailable. AIConfig.instance.verify() checks the live model list
  // directly against Groq's own API (using the user's key) at startup
  // and switches automatically — see ai_config.dart.
  // Groq officially deprecated both of the models previously configured
  // here (llama-3.3-70b-versatile, llama-3.1-8b-instant) on June 17,
  // 2026 — confirmed directly against Groq's own deprecations page,
  // which names these exact two replacements. Every Groq call this app
  // made was very likely hitting a `model_decommissioned` error since
  // that date — confirmed on a real device: adding a valid personal key
  // still produced "something went wrong" on every request.
  static const String groqPreferredModel = 'openai/gpt-oss-120b';
  static const String groqFallbackModel = 'openai/gpt-oss-20b';
  static const List<String> groqSupportedModels = [
    groqPreferredModel,
    groqFallbackModel,
  ];

  // ---- Voice routing ----
  // wazobiaVoice*/yarnGpt* config removed (PROJECT_MIGRATION_AUDIT.md
  // Phase 5) — TTS moved fully on-device, then TTS itself was removed
  // from the app entirely (see pubspec.yaml's removal notes). No voice
  // routing config of any kind is left — audio Bible content is now
  // pre-recorded and downloaded (see audio_bible/ at the repo root),
  // not synthesized.

  // ---- YouTube (DCLM sermon library / live programs) ----
  // Channel identity verified two independent ways: dclm.org's own
  // "Official Websites & Social Handles" page (which explicitly warns about
  // fake accounts) lists the handle as youtube.com/dclmhq, and fetching
  // that channel page directly resolves to this channel ID. Do not swap
  // this for any of the many national-branch DCLM channels (Netherlands,
  // Ghana, Tanzania, New Jersey, etc. all have their own separate
  // channels) — this is the global HQ channel only.
  static const String youtubeChannelId = 'UC4zsqN5YdXfxkkdVvwNA3JA';
  static const String youtubeChannelHandle = '@DCLMHQ';

  // PROJECT_MIGRATION_AUDIT.md Phase 3: the client calls the YouTube Data
  // API v3 directly again — per spec §24/§25, this key is treated as
  // PUBLIC, not secret, unlike the Groq key. It ships in the app
  // deliberately, on the understanding that it MUST be restricted in
  // Google Cloud Console before a real release:
  //   - API restriction: YouTube Data API v3 only
  //   - Application restriction: Android package name + SHA-1
  //     certificate fingerprint (and/or iOS bundle id, if shipped there)
  // An unrestricted key pasted here is a real liability — a restricted
  // one only works from this app's own signed build, which is the whole
  // point of "public but restricted" vs. "secret." This supersedes the
  // youtube-sync Cloudflare Worker that used to hold it server-side —
  // that Worker, and the rest of cloudflare/, was deleted outright (no
  // cloud infrastructure of any kind remains in this app). Its
  // live-status push-notification logic has no replacement yet — see
  // PROJECT_MIGRATION_AUDIT.md for that gap.
  static const String youtubeApiKey = String.fromEnvironment(
    'YOUTUBE_API_KEY',
    defaultValue: 'YOUR_RESTRICTED_YOUTUBE_API_KEY',
  );
  // ^ Passed at build time via --dart-define=YOUTUBE_API_KEY=... (see
  // README.md's build instructions) rather than hardcoded directly —
  // same "not scattered across Dart files" rule §24 asks for, just
  // satisfied without a server hop this time since the key itself is
  // meant to be public. Falls back to an obvious placeholder so a
  // misconfigured build fails at the YouTube API (401/403) instead of
  // silently pretending to work.

  static const int youtubeMaxUploadsPerSync = 25;
  static const Duration youtubeSyncInterval = Duration(minutes: 10);

  // ---- Daily content (Verse/Prayer workers) ----
  // dailyVerseCollection/dailyPrayerCollection removed
  // (PROJECT_MIGRATION_AUDIT.md Phase 4) — VerseWorker/PrayerWorker are
  // fully local now (deterministic date-seeded verse pick + optional
  // Groq-generated prayer), no Firestore doc to coordinate through.

  // ---- Programs (ProgramWorker) ----
  // Recurring church-schedule rules — bundled as a local JSON asset
  // (assets/data/programs.json) rather than a remote collection. See
  // ProgramWorker for how it's loaded/parsed.
  static const String programsAssetPath = 'assets/data/programs.json';

  // Firestore-era collection constants (workerLogsCollection,
  // featureFlagsCollection, bookmarksCollection, syncLogsCollection,
  // downloadLogsCollection) all removed — Firebase/Firestore is gone
  // from this app entirely. TTS error logging is now a local, rotating
  // log file (see tts_error_logger.dart); bookmarks/notifications/quiz
  // results/AI history all live in Drift.

  // A small built-in verse reference list used only as an offline seed /
  // last-resort fallback if VerseWorker has never successfully run for
  // today and there's no connection — NOT a replacement for real reading
  // plans (see VerseWorker doc comment).
  static const List<String> verseFallbackReferences = [
    'John 3:16',
    'Psalms 23:1',
    'Philippians 4:13',
    'Romans 8:28',
    'Proverbs 3:5-6',
    'Isaiah 41:10',
    'Jeremiah 29:11',
    'Psalms 46:1',
    'Matthew 11:28',
    '2 Corinthians 5:17',
  ];
}
