# Project Migration Audit — V1 (current repo) vs V2 (local-first spec)

Written from actually reading the code in this zip, not from the spec's
wishlist. The repo already has its own honest `FINAL_AUDIT_REPORT.md`
from a prior pass — this document doesn't repeat that; it maps the gap
between what's *actually* implemented today and what the V2 prompt asks
for, so nothing here is assumed or invented.

## 1. What V1 actually is

This is not a prototype. It's a working, fairly mature app with real
tradeoffs already made deliberately:

- **Auth**: Firebase Auth (email/password) + Firestore user doc on signup.
  `AuthService` mints a Firebase ID token used as a Bearer token against
  Cloudflare Workers.
- **Storage split**: Isar for Bible only (5 languages imported, ~28MB of
  bundled JSON in `assets/bible/`). Everything else — bookmarks, verse/
  prayer-of-the-day, YouTube cache — lives in **Firestore**, not local
  storage. This is the single biggest divergence from V2's "local
  database holds everything" model.
- **TTS**: Cloud, not on-device. `GradioClient` calls two hosted HF
  Spaces (WazobiaVoice for English/Hausa/Igbo/Pidgin, YarnGPT-local for
  Yoruba) over REST. `TtsService` retries/handles cold starts and cold
  Spaces sleeping. No MMS models, no ONNX/TFLite runtime, nothing
  bundled — this is a from-scratch build under V2, not a swap.
- **Secrets**: Already correctly out of the client. Groq and YouTube API
  keys live in two Cloudflare Workers (`cloudflare/groq-proxy`,
  `cloudflare/youtube-sync`), not in `.env` or Dart source.
  `.env.example` documents this; no real `.env` is bundled.
  `UserGroqKeyService` supports bring-your-own-key as an alternative path
  — this part already matches V2's "Groq is optional, user's own key,
  secure storage" intent, modulo the secure-storage requirement (see §3).
- **9 background workers** already exist client-side (sync, YouTube,
  program, verse, prayer, notification, conversation, cleanup, download)
  plus a parallel set of Firebase Cloud Functions doing schedule-driven
  versions of some of the same things — real duplication to resolve, not
  invent.
- **Radio**: real, verified DCLM Icecast/Airtime stream URLs per
  language (`AppConfig.dclmStreams`), cross-checked against DCLM's own
  site rather than guessed.
- **Tests**: 4 real pure-logic test files (reference parsing, canonical
  book registry, audio-cache hashing, ARB parity). Nothing exercises
  Isar or Firebase — deliberately, per `test/README.md`.
- **CI**: 6 GitHub Actions workflows exist, unverified against a real
  Flutter SDK (none available in any sandbox that's touched this repo
  so far).
- **Docs**: 13+ docs already exist and were previously audited as
  matching real implementation, not aspirational.

## 2. Gap map: V1 → V2 by spec section

| V2 requirement | V1 state | Gap size |
|---|---|---|
| Local-first DB (Drift/SQLite) holding everything | Isar, Bible-only; rest is Firestore | **Large** — new DB layer + migrate ~6 feature repos off Firestore |
| No Firebase Auth / no account system | Firebase Auth + Firestore user doc, full login/signup UI | **Large** — remove auth screens, build local onboarding, rewrite every service that currently takes a Firebase ID token as a Bearer credential (Groq proxy auth, in particular) |
| No cloud TTS; on-device MMS/ONNX/TFLite | Cloud TTS via 2 HF Spaces, no on-device inference anywhere | **Very large** — this is new ML packaging work (model conversion, runtime integration, tokenizer/vocoder, per-language model sourcing), not refactoring |
| TTS chunked streaming queue (play chunk N while generating N+1) | `BibleTtsQueue` exists (86 lines) but is a queue, not a chunked-generation-ahead pipeline; no evidence of prefetch-while-playing | **Medium** |
| YouTube via client-side Data API v3 calls, cached locally | Goes through `youtube-sync` Cloudflare Worker, which itself writes to Firestore (flagged in the prior audit as the highest-risk untested piece) | **Medium** — direction reverses: V2 wants the client calling YouTube directly (with a restricted, public key) instead of proxying through a Worker |
| Local notifications only | `notification_worker.dart` + `notification_service.dart` exist; need to confirm no FCM dependency remains once Firebase is pulled | **Small–Medium**, pending verification |
| Workers replaced with local Workmanager-style tasks | 9 client workers + duplicate Cloud Functions | **Medium** — mostly consolidation: drop the Cloud Functions half, verify the client half doesn't assume Firestore |
| Secure storage for Groq key | `UserGroqKeyService` exists — need to verify it's `flutter_secure_storage`-backed and not `shared_preferences` | **Small**, pending verification |
| Downloads, bookmarks, highlights, notes, reading progress | Already implemented (bookmarks pre-existing + extended to Bible verses this pass; downloads pre-existing) | **Small** — mainly a storage-backend swap if these currently touch Firestore for non-Bible data |
| Localization (5 languages, ARB) | Done — 5 ARB files, ARB-parity test exists, but `bible_screen.dart` is flagged as NOT localized (hardcoded English) | **Small** |
| CI/CD | 6 workflows exist | **None-Small** — likely just needs re-validation post-migration |
| Test suite breadth (importer, TTS queue, download manager, etc.) | 4 tests total, none touching Isar/Drift/Firebase | **Large** relative to V2's ask, though this was already an acknowledged gap pre-V2 |

## 3. Things worth flagging before any code changes

- **Groq proxy auth is built on Firebase ID tokens.** Removing Firebase
  Auth isn't a clean subtraction — `groq-proxy` verifies the Bearer
  token against Google's JWKS. V2's "no account system" removes the
  identity the Worker currently uses to rate-limit the shared 20/day
  cap. This needs a replacement scheme (e.g. device-generated key +
  Worker-side per-device counter) before Firebase Auth can actually come
  out, or the shared-proxy tier has to be dropped in favor of
  bring-your-own-key only.
- **`youtube-sync` Worker writes to Firestore itself** using a hand-rolled
  OAuth2 Google Service Account flow — the prior audit already flagged
  this as the highest-risk, least-tested part of the app. V2 wants this
  logic moved client-side entirely (direct YouTube Data API v3 calls +
  local cache), which is a rewrite, not a migration, of that Worker's
  purpose.
- **On-device TTS is the largest single item in the entire V2 spec** and
  is not a refactor of anything that exists — it's new model sourcing,
  conversion, mobile runtime integration, and per-language validation
  work (the spec itself says not to fabricate a Pidgin MMS model if none
  validated exists). This alone is bigger than the rest of the migration
  combined.
- **No Flutter SDK is available in any environment that has touched this
  repo** (noted in the prior audit too), so nothing here has been
  compiled, run, or tested — only read and reasoned about statically.

## 4a. Phase 1 progress (Local DB foundation) — in progress

Done this pass:
- `core/database/app_database.dart` — new Drift schema: `BibleBooks`,
  `BibleChapters`, `BibleVerses`, `BibleImportRecords` (1:1 port of the old
  Isar Bible schema), `Bookmarks`, `Highlights`, `Notes`,
  `ReadingProgress`, `ReadingStreak` (port of the old Isar annotations
  schema + the Firestore-backed bookmarks collection, now generalized to
  cover bible/sermon/aiConversation bookmark types), and `LocalProfiles`
  (new — not yet wired to onboarding; that's Phase 2).
- `bible_repository.dart`, `bible_annotations_repository.dart`,
  `bible_importer.dart`, `bookmark_repository.dart` rewritten against
  Drift. Method signatures kept as close to the originals as Drift's API
  allows, so callers needed a type-rename diff, not a logic rewrite.
- `bookmark_item.dart` — dropped the `uid` field and Firestore
  (de)serializers; deterministic id collapsed from uid+type+refId to
  type+refId now that there's exactly one local user.
- Callers updated: `bookmark_button.dart`, `bookmarks_screen.dart`,
  `search_screen.dart`'s bookmark-search branch, `verse_worker.dart`,
  `bible_providers.dart`, `bible_screen.dart` (~950 lines, type-renamed
  from `BibleXEntity` to Drift's generated row classes — no logic
  changes since it never touched Isar directly, only through the
  repositories above).
- `isar_service.dart` trimmed to only open `BibleAudioCacheEntity` — the
  one collection deliberately NOT migrated this pass (see below).
- Deleted `bible_local_schema.dart` and `bible_annotations_schema.dart`
  (dead code once nothing references the Isar entity classes).
- `pubspec.yaml` — added `drift`, `sqlite3_flutter_libs`, `path`,
  `flutter_secure_storage` (for Phase 2's Groq key move), `drift_dev`.
  `isar`/`isar_flutter_libs` deliberately left in for the audio cache.

Deliberately NOT done this pass (so this doesn't silently balloon into a
different, undiscussed piece of work):
- **`bible_audio_cache.dart` stays on Isar.** It's TTS-cache metadata that
  Phase 5 (on-device TTS) will replace wholesale — porting it to Drift now
  would be thrown away almost immediately.
- **Non-Bible Firestore data (YouTube cache, downloads, AI conversations,
  app settings) is untouched.** Only bookmarks moved, because
  `BookmarkItem`/`BookmarkRepository` were small and self-contained enough
  to fully finish in one pass without leaving a half-migrated feature.
  YouTube/downloads/AI conversations remain on Firestore/SharedPreferences
  until their own phases.
- **`LocalProfiles` table exists but nothing writes to it yet.** Wiring
  onboarding to it, and actually removing Firebase Auth, is Phase 2 — and
  per §3 above, Phase 2 can't start cleanly until the Groq-proxy
  rate-limiting scheme is redesigned around something other than a
  Firebase ID token.
- **Not compiled.** No Dart/Flutter SDK is available in the environment
  this was written in — see the header comment in `app_database.dart`.
  `dart run build_runner build` needs to be run locally before any of
  this will actually build, and `flutter analyze`/`flutter test` need to
  pass before this is trustworthy, not just plausible.

## 4b. Phase 2 progress (Firebase Auth removal) — done, with one flagged loose end

Done this pass:
- **Groq-proxy rate-limiting unblocked** (this was the explicit blocker
  from §3): `cloudflare/groq-proxy/src/index.ts` now mints and verifies
  its own HS256 device tokens via `/registerDevice` instead of checking
  Firebase ID tokens. `device_identity_service.dart` (new, client-side)
  registers/stores/refreshes that token; `groq_service.dart` and
  `ai_config.dart` both use it now, with retry-once-on-401.
- **`LocalProfiles` is live**: `profile_repository.dart` rewritten
  against Drift (dropped uid/email/bio/photoUrl — not in the spec's
  local-profile field list). `onboarding_screen.dart` gained a real
  profile-details page (name, age group, gender, avatar) that writes to
  it and routes straight to `/home`.
- **Login/signup UI deleted**: `login_screen.dart`, `signup_screen.dart`,
  `auth_service.dart` removed. `app_router.dart`'s auth gate is gone —
  it now only gates on onboarding/profile completion, synchronously
  cached the same way `onboardingSeenCache` always was.
- **`main.dart`**: Firebase Auth's `authStateChanges` listener replaced
  with a `ProfileRepository.watch()` listener that drives
  `CleanupWorker`/`NotificationService` startup. `Firebase.initializeApp()`
  itself is deliberately still called — Firestore is still the backing
  store for notifications, quiz results, AI conversation history,
  YouTube cache, and downloads metadata, none of which migrated this
  pass.
- **`settings_screen.dart` / `profile_screen.dart`**: rewritten against
  the local profile; "Sign Out" is gone (nothing to sign out of).
- **The four remaining Firestore-uid consumers** (`notifications_screen.dart`,
  `quiz_screen.dart`, `ai_assistant_screen.dart`, `search_screen.dart`)
  now key by `LocalIdentity.id` (new — a synchronous cache of
  `LocalProfile.id`, set once at startup) instead of a Firebase uid.
  Their own Firestore backends are unchanged/unmigrated — this only
  swaps what stable identifier they key by, honestly documented in
  `local_identity.dart`'s header as a bridge that should disappear once
  those features move to Drift.
- **Dead code removed**: `commonSignOut`, `notificationsSignInPrompt`,
  `bookmarksSignInPrompt`, `settingsDefaultUserName` pulled from all 5
  ARB files (were only reachable from the now-deleted sign-in UI).
  `firebase_auth` pubspec entry removed; `cloud_firestore` deliberately
  kept.

**One flagged, not-fixed loose end**: `youtube_repository.dart`'s
`refresh()` now sends the new device token to the `youtube-sync` Worker
too (for consistency with the Groq proxy), but that Worker's own source
wasn't touched this pass — if it still verifies Firebase ID tokens (as
`groq-proxy` used to), this call will 401 until the Worker itself is
updated. That Worker rewrite belongs to Phase 3 (per §3's flag on
`youtube-sync` writing to Firestore via hand-rolled OAuth2, which is a
bigger change than the auth scheme alone) — not silently patched here to
avoid scope-creeping into that phase's actual work.

**Still not compiled** — same caveat as Phase 1: no Dart/Flutter SDK in
this environment. `dart run build_runner build`, `flutter analyze`, and
`flutter test` need to run locally before this is verified.

## 4c. Phase 3 progress (YouTube: client-side, no Worker proxy) — done

Per explicit direction: put the YouTube API key in the client instead of
proxying through Cloudflare, using the same "public but restricted"
model the original spec's §24/§25 already described for this specific
key (unlike the Groq key, which must stay server-side).

Done this pass:
- `app_database.dart` — new `YoutubeVideos` and `YoutubeLiveStatus`
  Drift tables, replacing the Firestore `youtube_videos`
  collection/`config/youtube_live_status` doc.
- `youtube_repository.dart` — fully rewritten to call the YouTube Data
  API v3 directly (channels → playlistItems → videos, plus a separate
  search.list live-detection call) and cache results in Drift.
  Categorization keywords, ISO 8601 duration parsing, and live-status
  detection ported 1:1 from `cloudflare/youtube-sync/src/youtube.ts` —
  same behavior, different runtime.
- `video_entry.dart` — `fromFirestore`/`toFirestore` replaced with
  `fromRow` (Drift row → domain object).
- `app_config.dart` — added `youtubeApiKey` (via `--dart-define`, not
  hardcoded — same "not scattered across Dart files" principle §24
  asks for, just without a server hop this time since the key itself
  is meant to be public), `youtubeMaxUploadsPerSync`,
  `youtubeSyncInterval`. Removed `youtubeSyncProxyBaseUrl`,
  `youtubeCacheCollection`, `youtubeLiveStatusDoc` (dead once nothing
  reads Firestore for this anymore).
- `program_worker.dart` — its one-shot live-status read swapped from a
  direct Firestore doc read to `YoutubeRepository.getLiveStatusOnce()`.
  Its *other* Firestore usage (the `programs` collection) is untouched —
  out of scope, different feature.
- `cloudflare/youtube-sync/` — marked deprecated in its README, not
  deleted. Its `/syncNow` sync logic is fully superseded, but its
  live-status-change **push notification** (`fcm.ts`) has no client-side
  equivalent yet (a closed app can't push its own notification when
  DCLM goes live) — kept as reference for whenever that gets rebuilt as
  its own lighter Worker.

**Real security tradeoff, stated plainly, not glossed over**: this key
ships inside the app binary. That's fine *only* if it's restricted in
Google Cloud Console to (a) the YouTube Data API v3 specifically and
(b) this app's Android package name + SHA-1 signing certificate (and/or
iOS bundle id). An unrestricted key pasted into `--dart-define` is a
real liability — anyone can extract it from the APK and use it against
your quota from any app. This is documented at the point of use
(`app_config.dart`'s `youtubeApiKey` comment), not just here.

**Still not compiled** — same caveat as every phase so far.

## 4d. Phase 4 progress (workers: local instead of cloud round trips) — in progress

Per explicit direction: make the workers actually run locally rather
than round-tripping through Firestore/Cloud Functions. Tackled the two
highest-value, fully-completable pieces this pass rather than
superficially touching all of them:

**VerseWorker / PrayerWorker — done.** This is spec §27's
DailyContentEngine exactly as written: date → stable seed → verse
selection, so every device agrees without needing to coordinate through
a shared Firestore doc at all. `VerseWorker` no longer touches Firestore
— pure deterministic local computation, reading verse text from the
already-local Bible DB. `PrayerWorker` keeps its optional Groq call
(a legitimate online feature per spec — "never make the home screen
*depend* on Groq" is different from "never call it") but dropped the
Firestore round trip; prayer text is cached locally per device instead
of synced cross-device, which was never actually required, just
convenient. `dailyVerseCollection`/`dailyPrayerCollection` removed from
AppConfig as dead.

**Notifications — done.** This is spec §33 literally: "local
notifications only, no FCM." `firebase_messaging` removed entirely.
New Drift tables (`AppNotifications` for history, `NotificationSchedules`
for per-reminder-type enable/hour/minute) replace the Firestore
`notifications` collection and FCM token registration.
`notification_service.dart` rewritten around
`flutter_local_notifications`: `zonedSchedule` + `DateTimeComponents.time`
for the three daily reminders (verse/prayer/reading — spec's exact list),
`show()` for immediate one-off notifications (download complete, wired
up this pass; sync complete not yet wired — see below).
`notification_worker.dart`'s categorization/dedup logic ported to read
from Drift instead of a Firestore stream. `download_worker.dart`'s old
Firestore `download_logs` completion write replaced with an actual local
notification — more useful to the user than a log entry no UI ever read.

**Explicitly NOT what this fixes**: FCM could notify a device about
something that happened on a *different* device or server (e.g. "DCLM
just went live," pushed to everyone at once, app closed or not). Local
notifications can't do that — that class of feature needs either the app
open and polling (already true for YouTube live status via
`YoutubeWorker`) or a genuine server push path, which is exactly the
`youtube-sync` Worker's still-deprecated `fcm.ts` piece flagged in Phase
3. Not silently pretended away here — spec §33 itself only asks for the
four notification *types* this now handles locally (daily verse/prayer/
reading reminders + download completion), not live-event broadcast.

**Still cloud-dependent, not touched this pass** (flagged, not hidden —
"all the workers" is a bigger scope than one pass could safely cover):
- `cleanup_worker.dart` — still reads/writes several Firestore
  collections directly, including cleaning up the now-orphaned
  `download_logs` collection that nothing writes to anymore post this
  pass's `download_worker.dart` change.
- `sync_worker.dart` — the generic offline-write-queue-then-flush-to-
  Firestore mechanism other workers build on.
- `conversation_worker.dart` — AI conversation history, still Firestore
  (consistent with Phase 1/2's explicit "AI conversations stay
  Firestore until their own phase" scoping).
- `download_worker.dart`'s task metadata itself (not the completion
  notification, which is now local) — need to check whether the task
  list is already local (SQLite/SharedPreferences via
  `download_repository.dart`) or also Firestore-backed; not verified
  this pass.
- `cloudflare/daily-content/` Worker — still exists server-side,
  generating the same daily verse/prayer content the client now computes
  independently. Nothing calls it from the client anymore as of this
  pass (VerseWorker/PrayerWorker never read its Firestore docs), so like
  `youtube-sync`, it should get the same deprecation-README treatment —
  not done yet, flagged for the next pass through this phase.

**Still not compiled** — same caveat as every phase so far.

**This pass added**:
- **`SyncWorker` deleted as dead code**, not migrated — its `queueWrite()`
  had zero callers anywhere in the app; only `.start()` was ever called,
  wiring a connectivity listener that flushed an always-empty queue.
  `ConversationWorker` (the only other worker with a similar offline-queue
  need) already has its own independent queue and never routed through
  it. Spec §49 calls this out explicitly — unused machinery gets removed,
  not kept "just in case." All doc-comment cross-references to it in
  other files updated to stop pointing at something that no longer
  exists.
- **`cleanup_worker.dart` partially migrated**: notification-history
  pruning moved from a Firestore batch delete to a local Drift `DELETE`
  (matching Phase 4's notification_service.dart rewrite). Its
  `sync_logs`/`download_logs` Firestore pruning removed entirely — both
  are now orphaned collections nothing writes to (download_worker.dart's
  completion write moved to a local notification this same phase;
  sync_logs was never actually written to, since SyncWorker's queueWrite
  had no callers even before deletion). `worker_logs` pruning
  **deliberately kept** — `tts_error_logger.dart` still writes there for
  real (TTS itself is cloud-based pending Phase 5), so that Firestore
  collection is still live, unlike the other two.
- `AppConfig.syncLogsCollection`/`downloadLogsCollection` constants
  removed as dead; `workerLogsCollection` kept.

**Still cloud-dependent, not touched this pass**:
- `conversation_worker.dart` / AI conversation history — still Firestore
  (consistent with Phase 1/2's explicit scoping: AI conversations get
  their own phase).
- `download_worker.dart`'s task metadata storage itself — not verified
  whether `download_repository.dart` is already local or also
  Firestore-backed.
- `tts_error_logger.dart` and TTS generation itself — cloud (HF Spaces),
  explicitly Phase 5's territory, the largest remaining item in the
  whole spec.
- `cloudflare/daily-content/`'s `cleanupSchedule` — still relevant
  server-side until `cleanup_worker.dart`'s remaining Firestore
  dependency (`worker_logs`) either moves local too or gets its own
  deliberate "stays cloud, TTS is cloud" decision recorded.

**Still not compiled** — same caveat as every phase so far.

## 4e. Phase 4 continued — scan for remaining gaps before Phase 5

Did a full sweep rather than moving straight to TTS, per explicit
direction. Found real issues, not just stale comments:

**Critical finding: `firestore.rules` was silently broken.** Every rule
gated on `request.auth != null` — but Firebase Auth was removed in Phase
2. Those rules didn't get more permissive or stay the same; every gated
collection became permanently unwritable/unreadable by the client,
because `request.auth` can never be non-null again. This wasn't
cosmetic — it would have quietly broken every remaining Firestore
feature the moment Phase 2 shipped, and nothing in Phases 2-4 had
exercised that path yet to surface it.

Fixed two ways:
1. **Rewrote `firestore.rules` from scratch** to match what's actually
   left in Firestore: `games`/`messages` (admin-seeded, public read,
   client can only append a cached AI summary/quiz onto `messages`),
   `worker_logs` (write-only, no personal data), `programs`/`feature_flags`
   (public read). Explicit deny-all fallback so a stale client pointed at
   an old collection name fails loudly instead of silently.
2. **Migrated the three collections that genuinely held private
   per-user data and had no way left to prove device identity to
   Firestore rules** — `ai_conversations`, `quiz_progress`, and (already
   done in earlier phases) `bookmarks`/`notifications` — to local Drift
   tables instead of leaving them insecurely open. New tables:
   `AiConversations`, `QuizAttempts`. `ai_assistant_screen.dart`,
   `search_screen.dart`, `quiz_screen.dart` all updated to match — no
   more `uid`/`LocalIdentity` gating needed anywhere.
   `conversation_worker.dart` simplified to a thin pass-through (a Drift
   write can't fail due to being offline, so the offline-queue machinery
   it used to own is gone) rather than deleted outright, since call
   sites already depended on its exact method shape.

**Also found while sweeping:**
- `message_overview_service.dart` was reading/writing the Firestore
  `youtube_videos` collection directly — orphaned since Phase 3 moved
  YouTube data to Drift and nothing else touches that collection
  anymore. Fixed: added an `aiOverviewJson` column to the existing
  `YoutubeVideos` Drift table and rewired this service to use it,
  instead of a second disconnected cache.
- `LocalIdentity` (introduced in Phase 2 as a bridge for exactly these
  four Firestore-uid consumers) is now itself dead code — every call
  site that read it got migrated to local storage in this same pass.
  Deleted, along with the now-unused write of it in `main.dart`.
- Two stale doc comments describing non-existent classes
  (`SettingsSyncService` in `app_settings_service.dart`, an outdated
  Isar claim in `download_repository.dart`) fixed for accuracy.

**Still cloud-dependent, confirmed correct to leave as-is:**
- `games`/`messages` (`message_repository.dart`, `games_repository.dart`) —
  admin-seeded catalog content, not user data. This is exactly the kind
  of "optional internet content update" the spec's architecture section
  explicitly allows staying online.
- `worker_logs` (`tts_error_logger.dart`) — real, still-active, tied to
  TTS being cloud-based until Phase 5.
- `programs` (`program_worker.dart`) — flagged in Phase 4's original
  pass, unchanged.

**Still not compiled** — same caveat as every phase so far. This pass in
particular is worth double-checking once a real SDK is available, given
how many files it touched.

## 4f. Phase 5 progress (on-device TTS) — yo/ha/pcm/eng shipped, Igbo closed out

**Decision, by explicit instruction: ship without Igbo on-device TTS.**
Not a gap left open by accident — a real, exhausted search, recorded here
so a future pass doesn't repeat the same dead ends.

Igbo on-device paths actually tried, and why each was ruled out:

| Source | Format | Outcome |
|---|---|---|
| `facebook/mms-tts-ibo` (raw + full_models) | fairseq VITS | Confirmed absent — live HTTP checks, twice, all 4 plausible path codes, both folders |
| `rnjema-unima/mms-tts-ibo-baseline` | HF transformers | Not a trained model — a fine-tuning config scaffold pointing at Yoruba's weights; its own card confirms Meta has no Igbo checkpoint |
| `waxal-benchmarking/mms-tts-ibo-rnjema101` | Coqui VITS (WaxalNLP) | Real trained weights, right architecture family — but its own maintainers flag it "WORK IN PROGRESS — DO NOT USE IN PRODUCTION." Worth revisiting if that status ever changes. |
| `chimezie90/igbo-tts-f5` (IkengaTTS) | F5-TTS (flow-matching DiT) | Real, validated, good quality — but wrong architecture (sherpa-onnx doesn't support F5-TTS) and needs a reference-audio clip per utterance (voice cloning, not text-in/audio-out); heavier compute than fits low-end Android |
| `multilingual-tts/VITS-OpenBible-Igbo` | Coqui VITS (OpenBibleTTS) | Repo confirmed real, checkpoint downloaded, speakers listed (6 real speaker names) — conversion got as far as `torch.onnx.export`'s dynamo tracer, which failed on VITS's dynamic control flow (data-dependent boolean masking, unbacked symbolic shapes) under both `strict=True` and `strict=False`. Root cause not fully diagnosed (log truncated before the real exception) when this was stopped. |
| Small (sub-1B) llama.cpp/GGUF models (OuteTTS, etc.) | LLM-token + vocoder | Checked directly — no Igbo language support in any confirmed small model |

Also checked and ruled out on non-technical grounds: `Shinzmann/sorotts` and
this org's own `Axiveri/WazobiaVoice` — both Orpheus-3B based (the
architecture already used for this app's *cloud* TTS today), which would
mean a ~4GB download and autoregressive generation that community reports
put at only ~2x realtime on high-end desktop GPUs — very unlikely to hit
usable speed on the low-end Android hardware this app targets, and a poor
fit for the "generate next chunk while current plays" streaming
requirement regardless of download size.

**What's actually shipped**: `tts_service.dart` routes Igbo to
`TtsLanguageUnavailableException` unconditionally — no fallback, no
degraded cloud path, by explicit instruction that this app has zero
cloud dependency for speech. `bible_screen.dart`'s Bible reader hides/
disables the "Listen" control for Igbo rather than let a user hit this
exception through a visible button (see its language-aware Listen
button logic).

**Reopening this later**: the `VITS-OpenBible-Igbo` path is the most
promising unfinished lead — real weights, right architecture, got
partway through conversion. If revisited, start from getting the actual
untruncated `torch.onnx.export` error (not the FX graph dump) before
attempting a fix, and consider bypassing Coqui's `export_onnx()`
convenience method in favor of calling `torch.onnx.export(...,
dynamo=False)` directly against `onnx_inference`, which uses the older,
less strict TorchScript-based tracer.

**Cleanup pass, same as Phase 4's §4e**: swept the whole repo for
dangling references after removing cloud TTS. Real bugs found and fixed,
not just stale comments:
- `audio_service.dart` — `AudioSource.wazobiaVoice`/`yarnGpt` enum
  values removed (nothing constructs them anymore); a new
  `AudioSource.onDeviceTts` value added since three files
  (`tts_service.dart`, `local_tts_engine.dart`, `system_tts_engine.dart`)
  already referenced it before it existed — a real compile error that
  would have gone unnoticed without this sweep. `play()`/`playQueue()`
  never actually handled `file://` URLs (planned early in Phase 5,
  never implemented before other work intervened) — every on-device
  `TtsResult` returns one, so this was a real, live bug; fixed with an
  explicit `file://` → `setFilePath` branch.
- `bible_audio_cache.dart` — its `sourceFor()` fallback still referenced
  the now-deleted `AudioSource.wazobiaVoice`.
- `tts_error_logger.dart` — rewritten; its `logRetry`/`GradioErrorType`
  params were specific to the cloud engine's retry-on-cold-start
  behavior, meaningless for local synthesis.
- `settings_screen.dart` — real user-facing bug, not just dead code: its
  language/voice picker still showed "Igbo (WazobiaVoice — Adaeze)" as
  if a voice existed for it. Fixed to accurately describe each
  language's actual voice status, and added a real "Offline voices"
  entry point to `VoiceDownloadSheet` (previously only reachable
  reactively, via a failed play attempt).
- `gradio_client.dart` deleted outright — zero remaining callers.
- `AppConfig`'s dead WazobiaVoice/YarnGPT constants removed.

## 4g. CI/CD audit — real bugs found, not just staleness

Requested explicitly: update the GitHub Actions workflows and delete
useless ones. Two categories of finding.

**Genuinely broken, now fixed:**
- `flutter_analyze.yml`'s "Verify required workers exist" step still
  listed `SyncWorker` — deleted as dead code in Phase 4. This check
  would have failed CI permanently until this fix; it's since been
  folded into the consolidated `flutter_ci.yml` with the correct list.
- `release.yml` built the release APK/AAB **without**
  `--dart-define=YOUTUBE_API_KEY` — every real release build would have
  shipped with `AppConfig.youtubeApiKey`'s placeholder fallback string,
  silently breaking the YouTube/sermon-library feature on every device
  that installed it. Fixed, plus a loud `::warning::` step if the
  `YOUTUBE_API_KEY` secret isn't set when a release is tagged.

**Dead weight found while auditing, removed beyond just the workflows:**
`flutter_dotenv` was never actually read from anywhere — `dotenv.load()`
ran at startup, but nothing called `dotenv.env[...]`; the last real
reader (`HF_TOKEN`, for the old cloud TTS client) went away when
`gradio_client.dart` was deleted in Phase 5. Removed the package, the
`.env` asset declaration, the `dotenv.load()` call, and `.env.example`
itself — which simplified every workflow that had a "create .env from
.env.example" step, since none of them need one anymore.

**Consolidation**: `flutter_ci.yml`, `flutter_analyze.yml`, and
`flutter_test.yml` all triggered on the identical push/PR event and each
independently repeated `flutter pub get` + code generation + `flutter
gen-l10n` — real CI-minute waste, and three places for the same
"why this step exists" comments to drift out of sync (which they
already had). Merged into one `flutter_ci.yml` covering everything the
three used to (format check, analyze, TODO scan, required-workers
check, hardcoded-key scan, tests, coverage upload) in fail-fast order;
`flutter_analyze.yml`/`flutter_test.yml` deleted as now-fully-subsumed,
not just similar.

**Left alone, confirmed still legitimate**: `dependency_check.yml` and
`security_scan.yml`'s `functions/` jobs — that directory is the
documented legacy Cloud Functions rollback path, still genuinely
present in the repo, not stale.

**Still not compiled/run** — same caveat as every phase. A YAML syntax
check confirms every workflow file parses; it does not confirm a real
GitHub Actions run succeeds.

## 4h. CI: real bugs from a live GitHub Actions run — fixed with evidence

First real compiler/analyzer feedback this migration has had. Two
genuine compile errors, one real runtime bug, one leftover from an
earlier rename, and a full pass through every `--fatal-infos`-flagged
lint (35 total) across 18 files:

**Real compile/runtime bugs, not style:**
- `download_worker.dart` — `AccumulatorSink` used with no import in
  scope (Dart's "isn't defined for the type DownloadWorker" phrasing is
  the tell). Rather than guess which package re-exports it (already
  burned once this migration on an unverified package API — see the
  OpenBibleTTS notebook's `onnxscript` miss), replaced with a small,
  guaranteed-correct local `Sink<T>` implementation. Unused
  `dart:convert` import removed too.
- `bible_screen.dart` — a `.catchError()` on a `Future<BibleAudioCacheEntity>`
  whose handler didn't return one; fixed by converting to
  `Future<void>` first via `.then((_) {})` before `.catchError`.
- `ai_assistant_screen.dart` — a genuine leftover bug from the earlier
  `_isUsageLimitError` → `_needsGroqKey` rename (§4i below): one
  reference to the old field name survived, which would have been an
  undefined-identifier compile error.

**Lint sweep**: every `curly_braces_in_flow_control_structures` and
`prefer_const_constructors` hit from the log fixed, including in files
never touched by this migration (`games_screen.dart`,
`sermon_library_screen.dart`, `video_player_screen.dart`,
`learn_screen.dart`) — `--fatal-infos` doesn't distinguish "your bug"
from "pre-existing debt," so neither did this pass.
`learn_screen.dart`'s `use_build_context_synchronously` was a real bug,
not style: `ScaffoldMessenger.of(context)` used after an `await` with no
`mounted` guard, including in the `finally` block (a `return` inside
`catch` still runs `finally` in Dart, so that path needed its own guard
too). Every touched file's brace count verified balanced before/after.

**Stale-push flag, not a code issue**: the CI log itself referenced
`login_screen.dart`, `gradio_client.dart`, and `groq_usage_service.dart`
— all three deleted in earlier phases of this same session. That means
whatever's on GitHub right now predates a meaningful amount of this
work. Whatever gets pushed next needs to be a full overwrite of the
remote, not a selective sync, or this mismatch recurs.

## 4i. No cloud infrastructure at all — explicit instruction, fully executed

Per direct instruction: users supply their own API keys, so there's no
shared secret left to protect, so no server-side proxy is needed at
all. This is a stronger requirement than earlier phases' "no backend I
run myself, but a direct third-party API call is fine" pattern (Phase
3's YouTube approach) — it means the **Groq proxy goes too**, unlike
YouTube's embedded-key pattern which stays (that key is meant to be
public; Groq's is meant to be the user's own, never embedded).

- **`cloudflare/` deleted outright** — all three Workers
  (`groq-proxy`, `youtube-sync`, `daily-content`), not just the two
  already-deprecated ones. Keeping unused-but-present Worker code
  contradicts "no cloud" even when nothing calls it.
- **`GroqService`/`AIConfig` rewritten**: personal Groq key is now
  mandatory, not optional-but-nicer. No shared-proxy fallback path
  exists anywhere in the code. Both call Groq's real API directly.
- **`device_identity_service.dart` and `groq_usage_service.dart`
  deleted** — both existed only to support the now-gone shared-proxy
  path (device-token auth, shared daily quota).
- **`UserGroqKeyService` migrated to `flutter_secure_storage`** — was
  plaintext `SharedPreferences` despite `flutter_secure_storage`
  already being a dependency for exactly this (added early, never
  wired up — closed now that the key is mandatory, not optional).
- **Real UI-level bugs found and fixed**, not just plumbing:
  `settings_screen.dart`'s language picker still displayed
  "Igbo (WazobiaVoice — Adaeze)" as if a voice existed; its Groq-key
  dialog still advertised a "free shared limit" that no longer exists,
  in all 5 languages' ARB files, not just English; clearing a now-
  mandatory key went from a silent one-tap action to a real
  confirmation dialog, since the consequence changed (AI features
  fully stop working, not "falls back to shared tier").
- **Dependency sweep**: `connectivity_plus` (only caller was the
  already-deleted `SyncWorker`), `riverpod_annotation`, `freezed`/
  `freezed_annotation`, `json_serializable`/`json_annotation` all
  removed — confirmed zero real usage (`@riverpod`/`@freezed`/
  `@JsonSerializable` appear nowhere in `lib/`). This also removes the
  `isar_generator`-vs-`freezed` version-pin workaround that only
  existed to accommodate a package nothing used.
- **`firestore.indexes.json` rewritten** — it still defined composite
  indexes for `ai_conversations`, `notifications`, `bookmarks`,
  `youtube_videos`, every one of which is fully local now. Checked what
  queries the *surviving* Firestore collections actually run before
  rewriting: only `messages`' `category`+`created_at` query is a real
  composite; `games`/`programs`/`worker_logs` all query a single field,
  which Firestore auto-indexes, so they need no entry at all.
- **README.md rewritten wholesale**, not patched — it predated most of
  this migration and described Cloudflare Workers, a shared Groq key,
  and Firebase Auth as current architecture, none of which exist
  anymore.

## 4j. Radio artwork + final cleanup pass before push

**Radio lock-screen artwork**: real DCLM/Deeper Life Bible Church
branding, not invented — pulled from the user-supplied
`dclm-radio-app-v1-main.zip` (the official radio.dclm.org web player's
own source). Checked the actual candidate images before picking one:
`favicon.png` and `assets/img/album-art/d.png` are identical files —
that naming (`d.png` = default) combined with the duplication confirms
it's genuinely the site's own default now-playing artwork fallback, not
a guess. Copied to `assets/images/dclm_radio_art.png`, wired into
`RadioService`'s `MediaItem.artUri` via `asset:///`. Dynamic per-track
art (the AzuraCast now-playing API's `song.art`, already fetched by
`_fetchNowPlaying`) is NOT wired to the live lock-screen thumbnail —
that needs `audio_service`'s mediaItem-update API, more machinery than
`just_audio_background` alone provides. Static station art is a real
improvement over no art at all, not represented as the final state.

**`functions/` deleted outright**, not just left as a rollback path —
its own reason for existing (rolling back to the Cloudflare-Worker
architecture) stopped applying once that architecture was deleted too
(§4i). `firebase.json` kept, trimmed to just the `firestore` block —
still genuinely needed to deploy `firestore.rules`/`indexes.json` for
the collections that legitimately remain. Its dead `functions` deploy
config removed. `dependency_check.yml`'s `functions-dependencies` and
`security_scan.yml`'s `functions-audit` jobs removed — both were
checking a directory that no longer exists. `security_scan.yml`'s
secret-scan step's `.ts` file pattern dropped (functions/ was the only
TypeScript source) and its comment updated to reflect why the scan
matters *more* now, not less: every user's own real Groq key now lives
in the app, not a shared project secret.

**`CLOUD_FUNCTIONS.md`** given an explicit deletion notice rather than
left silently describing code that no longer exists — its entire
subject matter is gone, unlike the other historical docs (which are
only partially stale and already flagged as such in README.md).

## 4k. Radio: all 18 verified languages wired into the picker

Only 4 of `AppConfig`'s 18 verified DCLM language streams were ever
exposed in `live_screen.dart`'s picker — the other 14
(`dclmExtraStreams`) were real, verified, and sitting unused since
whoever wired the original 4 up. Fixed:

- Added `AppConfig.dclmLanguageLabels` — one shared display-name map for
  all 18 languages, used by both `live_screen.dart`'s picker and
  `RadioService`'s `MediaItem` title. Previously each file kept its own
  4-language `switch` statement; a genuine source of the kind of drift
  this migration has hit before (two copies of the same fact,
  guaranteed to eventually disagree).
- Picker now lists all 18, grouped (the original 4, then a divider,
  then the 14 extras) rather than an undifferentiated flat list.
- `RadioService.playLanguage()` already checked both stream maps
  (`dclmStreams[key] ?? dclmExtraStreams[key]`) — no change needed
  there, this was purely a UI-exposure gap.

## 4. Suggested phase order (not started — for discussion)






1. Local DB foundation: stand up Drift, migrate Bible off Isar, migrate
   the non-Bible Firestore-backed features (bookmarks/highlights/notes/
   progress/settings) to Drift. Bible dataset re-import unaffected either
   way since it's already sourced from bundled JSON. **In progress — see
   §4a for exactly what's done vs. deliberately deferred.**
2. Remove Firebase Auth → local profile onboarding. **Done — see §4b.**
   One flagged loose end: the `youtube-sync` Worker itself still needs
   updating to verify device tokens instead of Firebase ID tokens.
3. YouTube: move from Worker-proxied to direct client-side Data API v3 +
   local cache; retire `youtube-sync` Worker's sync path (its push-
   notification piece kept as reference, not fully retired). **Done —
   see §4c.**
4. Local notifications: verify/finish the FCM-free path.
5. On-device TTS: **done for yo/ha/pcm/eng — see §4f.** Igbo shipped
   without a voice, by explicit instruction — no cloud fallback anywhere
   in the app. Real remaining gap: model download picker/AI-disclosure
   UI is built but, like everything else in this migration, untested
   against a live SDK.
6. Test/CI backfill against whatever of the above actually landed.

This is offered as a starting order, not a commitment — happy to start
wherever you want given real priorities (e.g. shipping something
demoable vs. removing the riskiest untested piece first).
