# Changelog

This project has been built across multiple sessions without version
tags/releases yet (pre-1.0, no app store submission has happened). This
log groups changes by session/pass rather than semantic version, since
none have been cut yet — switch to proper semver once there's a first
real release build.

## Unreleased — this pass

- **Offline game import (Games feature).** Users can now import their own
  packaged HTML5 game as a `.zip` (index.html + assets, optional
  `manifest.json`/`thumbnail.png`) via a picker on the Games screen —
  extracted to app storage and played fully offline through
  `WebViewController.loadFile`, no network involved before or after
  import. New `LocalGames` Drift table (schema v1→v2, additive-only
  migration), `GameImportService` (zip-slip-safe extraction), and
  `LocalGamesRepository`. Bundled `assets/data/games.json` (online,
  launch/embed URL) is unchanged and untouched — the Games grid now
  merges both sources, local entries first, long-press to remove a
  local one.
- **CI cleanup.** `release.yml` dropped its dead Firebase steps (write
  `google-services.json`, apply the Google Services Gradle plugin) —
  the app never calls `Firebase.initializeApp()` and has no
  `firebase_core` dependency, so these ran for nothing. Android release
  signing and the YouTube API key build-define are untouched, both are
  real. `dependency_check.yml`'s lockfile check was silently a no-op
  (`git diff` against an untracked `pubspec.lock` always reports no
  changes) — now fails loudly if `pubspec.lock` isn't committed instead
  of pretending to verify it.
- **Blaze is now genuinely, fully avoidable — closing the honesty gap
  from the previous entry below.** New Worker,
  `cloudflare/daily-content/`, with 3 Cron Triggers (Workers Free plan
  allows up to 3 per Worker), supersedes `dailyVerseSchedule`,
  `dailyPrayerSchedule`, and `cleanupSchedule`. The two Firestore-
  triggered notification functions this couldn't mechanically port
  (`onDailyVerseCreated`, `onDailyPrayerCreated` — Workers has no
  Firestore-trigger equivalent) are folded inline instead: the same
  Worker call that writes today's verse/prayer doc also sends the push,
  right after, using FCM's HTTP v1 API with the same service-account
  OAuth2 pattern already built for Firestore access (different scope).
  `onLiveStatusChanged` got the same treatment, folded into
  `cloudflare/youtube-sync/`'s existing sync job (see that Worker's
  updated `youtube.ts`/new `fcm.ts`) instead of a fourth Worker.
  `functions/` is fully superseded now — kept in the repo only as a
  manual rollback option, not required for anything. See
  `cloudflare/daily-content/README.md` for the research that went into
  this (why a polling approach was considered and rejected in favor of
  inlining the notification into the write) and every Worker's own
  honest-caveats section for what's still unverified.

- **YouTube sync also moved off Firebase** — `cloudflare/youtube-sync/`
  now handles both the on-demand refresh (`/syncNow` endpoint) and the
  15-minute schedule (Cloudflare Cron Trigger), replacing
  `syncYoutubeNow`/`youtubeSyncSchedule`. This one also writes to
  Firestore itself, via a real Google Service Account (hand-rolled
  OAuth2 JWT flow using Web Crypto, since there's no `firebase-admin` for
  Workers) — flagged as the highest-risk untested piece of this project.
  `cloud_functions` removed from `pubspec.yaml` — nothing in the client
  calls a Firebase callable anymore.
- ~~**Honesty note added**: migrating Groq + YouTube sync does NOT mean
  Firebase Blaze is fully avoidable~~ — **closed above, this same pass**:
  `dailyVerseSchedule`, `dailyPrayerSchedule`, `cleanupSchedule`, and the
  notification fan-out triggers are now migrated too. Left this entry
  struck through rather than deleted so the "was this actually true at
  the time" history stays legible — same reasoning `PHASE2_NOTES.md`
  uses for keeping superseded sections rather than rewriting history.

- **Groq moved off Firebase entirely.** `groqChat`/`groqModels` are no
  longer called by the client — `GroqService`/`AIConfig` now call a
  Cloudflare Worker (`cloudflare/groq-proxy/`) instead, specifically to
  avoid requiring the Firebase Blaze plan for this. Verified current
  (2026) free-tier numbers before recommending this (100k requests/day,
  no card required). Firebase ID token verification happens in the
  Worker itself (against Google's public JWKS), since a plain Worker
  doesn't get `request.auth` for free the way a Firebase callable does.
- **iOS-style animations app-wide, not just Bible.** Set
  `CupertinoPageTransitionsBuilder` in the shared theme — every screen
  in the app now gets the iOS push/pop slide instead of Android's
  default, with one change instead of per-screen work. Deliberately just
  the platform-standard transition, not a custom one — matches the
  "smooth, not over-animated" direction.
- **Premium icon/styling pass**: swapped Material icons for
  `CupertinoIcons` on the Radio/Live screen, AI Assistant, and Quiz
  screens. Rebuilt the Radio screen's player with a real premium card
  (gradient + soft shadow), a proper circular play/pause button with a
  restrained tap-scale + icon crossfade (replacing a bare 64px Material
  icon), and an animated reveal for the "now playing" info. Quiz screen
  now animates in on completion and crossfades answer-option colors/icons
  instead of snapping.

- **Bug fixes from a dedicated audit pass**: `BibleTTSQueue`'s prefetch
  buffer had a crash bug (RangeError on any chapter with more than
  `prefetchDepth + 1` chunks — i.e. almost every real chapter), fixed and
  verified against 24 test combinations. `GradioClient` leaked an HTTP
  client on every TTS request, fixed. Settings screen showed stale
  Groq-key state after save/clear, fixed via proper Riverpod provider
  invalidation instead of a bare `FutureBuilder`.
- **Fixed a real CI gap**: `flutter_ci.yml`, `flutter_analyze.yml`, and
  `flutter_test.yml` never generated Isar's `.g.dart` files or the
  localization code before running `flutter analyze`/`flutter test` —
  meaning all three would fail today on "target of URI doesn't exist"
  before reaching any real issue. Added the missing `build_runner`/
  `gen-l10n` steps to all three.
- **`release.yml` now generates `android/`/`ios/` in CI** via
  `flutter create .` (safe there — the runner has a real Flutter SDK,
  unlike this sandbox) instead of just documenting the gap. Also wired up
  real Android release signing from GitHub Secrets
  (`ANDROID_KEYSTORE_BASE64` etc.) so the release build isn't stuck
  debug-signed — see `DEPLOYMENT_GUIDE.md`.
- Localized the remaining hardcoded Settings screen strings found in the
  last audit (Games, Language & Voice, Appearance, theme labels, AppBar
  title, Credits, default user name) — 10 more ARB keys × 5 languages.
  Settings screen is now fully localized.
- Fixed a real bug: `NotificationService.initialize()` re-subscribed to
  FCM listeners on every sign-in without cancelling prior subscriptions —
  a sign-out/sign-in cycle would duplicate every recorded push
  notification. Fixed with an idempotency guard + explicit cancellation.
- Localized the Settings "AI Assistant" section and the AI Assistant
  screen's usage-limit messaging (14 new ARB keys × 5 languages). Found
  (but did not fix, due to scope) that several pre-existing Settings
  sections were never localized either — see `FINAL_AUDIT_REPORT.md`.
- Expanded `DEPLOYMENT_GUIDE.md` with the specific Android manifest /
  iOS Info.plist entries this app's actual dependencies need
  (`just_audio_background`, `firebase_messaging`) — deliberately did not
  hand-fabricate `android/`/`ios/` folders themselves; see the audit
  report's reasoning.

- Added TTS error handling: `GradioClient` now classifies failures
  (cold-starting Space, rate limited, timeout, network, server error),
  `TtsService.synthesizeWithRetry` retries retryable failures with
  backoff, and `TtsErrorLogger` logs every retry/failure to Firestore —
  previously a cold-start or rate limit failed silently with no trace.
- Added `BibleTTSQueue` — real look-ahead prefetching so chapter audio
  chunk N+1 generates while chunk N plays, closing the "dead air between
  chunks" gap in Bible chapter listening.
- Added a daily usage cap (20/day) on the shared Groq key
  (`GroqUsageService`) to protect it from being exhausted by heavy users,
  and a "bring your own Groq API key" option in Settings
  (`UserGroqKeyService`) for unlimited access — when set, chat calls Groq
  directly with the user's own key instead of the shared callable.

- Fixed the emoji-as-icon in the reading streak indicator (replaced with
  `Icons.local_fire_department_rounded`); repo-wide scan confirmed no
  other emoji/sticker icons exist.
- Fully localized `bible_screen.dart` (23 new ARB keys × 5 languages, 3
  dead keys removed including one that was factually wrong — claimed no
  Pidgin Bible exists).
- Added restrained, iOS-style transition animations to the Bible screen
  (fade+slide between book/chapter/verse views, animated highlight
  colors, animated loading-state icon swaps) — deliberately not
  over-animated per explicit product direction.
- Added a real (if partial) test suite: pure-logic unit tests for Bible
  reference parsing, the canonical book registry, the audio-cache hash
  function, and an ARB localization-parity guard.
- Added Bible verse highlights (4-color palette), notes, "Continue
  Reading," and a cross-language daily reading streak.
- Added local disk caching for generated Bible chapter TTS audio —
  repeat plays no longer regenerate through the TTS Space.
- Fixed the YouTube Data API key exposure (client → `syncYoutubeNow`
  Cloud Function callable, `YoutubeRemoteDatasource` deleted,
  `YOUTUBE_API_KEY` removed from `.env.example`).
- Fixed the Groq API key exposure (client → `groqChat`/`groqModels`
  Cloud Function callables, `GROQ_API_KEY` removed from `.env.example`).
- Built the offline Bible engine end to end: real per-verse data for all
  5 languages reconstructed from source (see `BIBLE_IMPORT_NOTES.md`),
  Isar schema/importer/repository, reader UI, offline search (also wired
  into global Search).
- Wired Isar into the app for the first time (`IsarService`) — it was a
  declared dependency with nothing actually opening it before this pass.
- Wrote the initial documentation suite (this file, README, and
  everything else listed in README's "Docs index").

## Earlier sessions (pre-dating this log)

Not individually dated/logged — see `FINAL_AUDIT_REPORT.md`'s feature
table for what existed before this pass started (Home, AI Assistant,
Downloads, Bookmarks, Search, Notifications, Settings, Radio, Sermons,
onboarding/auth, 9 client workers, Cloud Functions scaffolding, CI
workflows, initial ARB localization for 6 screens).
