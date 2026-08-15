# EKKLESIA

Multilingual church companion app (English, Yoruba, Hausa, Igbo, Nigerian
Pidgin) — Bible, sermons/radio, AI assistant, and daily devotionals — built
with Flutter, brand EMEMZYVISUALS DIGITALS.

> **Status: pre-release, actively built across multiple sessions.** This
> README describes what's actually in the repository today, not the full
> target spec. See "What's not done yet" below before assuming a feature
> is complete. `PROJECT_MIGRATION_AUDIT.md` has the full phase-by-phase
> ledger and is more current than this README in places of overlap.

## Stack

- **Client**: Flutter, Riverpod, GoRouter, Drift (local SQLite — the
  primary datastore), just_audio, sherpa_onnx (on-device TTS), flutter_tts
  (system TTS for English).
- **No backend of any kind runs for this app.** No account system, no
  shared API keys, no proxy server, no Cloudflare Workers — all deleted.
  What little Firestore usage remains (see below) is read-only,
  admin-seeded content; the client never authenticates to reach it.
- **AI**: Groq (chat, sermon summaries, quiz generation) — called
  **directly** from the client. Every user supplies their own Groq API
  key (Settings → AI), stored in secure storage. There is no shared key,
  no free tier, no fallback: AI features simply don't work until a key
  is added. See `GroqService`/`AIConfig`'s doc comments.
- **YouTube**: YouTube Data API v3, called **directly** from the client
  with a restricted, embedded key (public-but-restricted by design — see
  `AppConfig.youtubeApiKey`'s doc comment). Cached locally in Drift.
- **TTS**: on-device only, per language:
  - English → system TTS (`flutter_tts`)
  - Yoruba, Hausa, Nigerian Pidgin → downloaded MMS ONNX models, run via
    `sherpa_onnx` — see `TTS_ARCHITECTURE.md` and
    `Renpiper-mms-onnx-V1_build_and_publish.ipynb`
  - Igbo → **no voice available.** Every real, checked option (Meta's
    MMS, several community fine-tunes, an OpenBibleTTS VITS conversion
    attempt) was ruled out or left unfinished — see
    `PROJECT_MIGRATION_AUDIT.md` §4f for the full record, including what
    to try next if this gets revisited. No cloud fallback exists for
    Igbo specifically or for TTS generally.
  - Users download voices on demand (Settings → Offline voices, or
    prompted the first time a chapter is played in a language that
    needs one) — nothing is bundled in the app or auto-downloaded
    silently.

## Repository layout

```
lib/
  core/            App-wide config, services (tts, audio, workers), shared Result type
  features/
    bible/         Offline Bible engine — Drift-backed, on-device TTS
                   (see BIBLE_IMPORT_NOTES.md, TTS_ARCHITECTURE.md)
    sermons/       YouTube Data API v3 called directly by the client + radio
    ai/            Groq-backed chat assistant, direct client call —
                    conversation history Drift-backed, no account needed
    bookmarks/     Cross-feature bookmarking — Drift-backed, no account needed
    downloads/     Download queue/manager
    search/        Federated search across Bible/sermons/bookmarks/downloads/AI/settings
    notifications/ In-app notification center — Drift-backed, local
                    scheduled reminders (no push, no FCM)
    settings/, profile/, onboarding/, home/, learn/, games/
    (auth/ no longer holds sign-in screens — there is no account system;
    it still holds avatar_service.dart/avatar_picker.dart, reused by
    onboarding/profile)
assets/bible/      Bundled per-language Bible datasets (en/yo/ha/ig/pcm JSON + manifest)
assets/images/     dclm_radio_art.png — real DCLM/Deeper Life Bible Church
                   branding (from the official radio.dclm.org web player's
                   own default now-playing art), used as the lock-screen/
                   notification thumbnail for radio playback.
tools/             build_bible.py — regenerates assets/bible/*.json from raw sources
PROJECT_MIGRATION_AUDIT.md   Living record of the local-first migration —
                   read this first, it's more current than this README
                   in places (Phases 1-5 done; see it for exact status,
                   including a live-CI-log fix history).
```

## Setup

1. **Flutter dependencies**
   ```
   flutter pub get
   ```
2. **Generate Drift's `.g.dart` files** — required before anything
   compiles; this repo was built in a sandbox with no Flutter SDK, so
   these were never generated locally:
   ```
   dart run build_runner build --delete-conflicting-outputs
   ```
3. **Firebase** — only needed for the handful of collections that are
   still admin-seeded, read-only content: `games`, `messages` (quiz
   content), `worker_logs` (TTS error logging), `programs`. No Auth, no
   Cloud Functions (deleted outright, along with the Cloudflare Workers
   that had already superseded them — see `CLOUD_FUNCTIONS.md`), no
   client-side write access beyond the one narrow field Firestore rules
   allow — see `firestore.rules`. See `FIREBASE_SETUP.md`.
4. **Environment** — no `.env` file at all (removed — nothing read a
   value out of it once cloud TTS/the shared Groq proxy were both
   deleted). `YOUTUBE_API_KEY` is passed at build time via
   `--dart-define` (see `AppConfig.youtubeApiKey`'s doc comment for why
   it's meant to be public-but-restricted). Groq needs no build-time
   secret at all — each user enters their own key in-app.
5. **Run**
   ```
   flutter run --dart-define=YOUTUBE_API_KEY=your_restricted_key
   ```

## What's actually done

- Home (live verse/prayer/program cards — verse/prayer computed fully
  on-device, no server round trip), Bible (offline, all 5 languages —
  reading, search, highlights, notes, bookmarks, continue reading,
  on-device chapter narration for en/yo/ha/pcm with local audio
  caching), AI Assistant (direct Groq call, user's own key required),
  Downloads, Notifications (local, scheduled — no push), Bookmarks,
  federated Search, Settings (including an offline-voice download
  picker), Profile (local, no account), Radio (DCLM stream), Sermons
  (YouTube Data API v3 called directly by the client).
- No account system, no cloud infrastructure: no Firebase Auth, no
  Cloudflare Workers, no shared API keys of any kind. Onboarding
  collects a local profile (name/age group/gender/language/avatar) and
  writes straight to Drift — no sign-in, no network required to use the
  app for the first time.
- 8 background-style workers wired: Youtube, Program, Verse, Prayer,
  Notification, Conversation, Cleanup, Download.
- On-device TTS for 4 of 5 languages (see Stack section above for the
  honest Igbo gap) via downloaded MMS ONNX models + sherpa_onnx.
- Localization: 5 languages (en/yo/ha/ig/pcm), wired into 6+ screens.
- CI: 5 GitHub Actions workflows (consolidated CI — format/analyze/tests
  in one, dependency check, security scan, release, auto-format-fix).

## What's not done yet

- **Android/iOS platform folders don't exist.** Generating them requires
  a real Flutter SDK (`flutter create .`), which hasn't been available in
  the sandbox this was built in. Run that yourself once you have Flutter
  installed, then re-apply any platform-specific config from
  `DEPLOYMENT_GUIDE.md`.
- **No automated test suite** (unit/widget/repository/worker tests).
- **Nothing in this repo has been compiled by Claude.** No Dart/Flutter
  SDK exists in the environment any of this work was done in — every
  phase in `PROJECT_MIGRATION_AUDIT.md` is reviewed-by-reading, not
  verified-by-build, until a real `flutter analyze`/`flutter test` run
  confirms it. A live GitHub Actions run has already caught real bugs
  this way once — see `PROJECT_MIGRATION_AUDIT.md`'s CI section for what
  it found and how it was fixed; treat that as the expected pattern, not
  a one-off.
- **Igbo has no on-device (or any) TTS voice.** See the Stack section
  above and `PROJECT_MIGRATION_AUDIT.md` §4f for the full record of what
  was tried.
- Bible engine: no reading-streak-adjacent stats screen yet (streak is
  tracked and shown inline, but there's no dedicated stats page), no
  chunked prefetch-while-playing TTS streaming queue (chapters generate
  audio up front, then cache it — see `BIBLE_IMPORT_NOTES.md`).

## Docs index

- `PROJECT_MIGRATION_AUDIT.md` — the authoritative, current record of
  every phase of this app's local-first migration. Read this first.
- `SYSTEM_ARCHITECTURE.md`, `DATABASE_SCHEMA.md`, `API_REFERENCE.md`,
  `CLOUD_FUNCTIONS.md`, `WORKERS.md`, `OFFLINE_ENGINE.md`,
  `PHASE2_NOTES.md` — historical/point-in-time docs from earlier in the
  project. Some describe architecture (Cloudflare Workers, shared Groq
  key, Firebase Auth) that has since been removed — cross-check against
  `PROJECT_MIGRATION_AUDIT.md` before trusting anything in them about
  current backend/auth architecture specifically.
- `TTS_ARCHITECTURE.md` — on-device TTS: model sourcing, conversion
  pipeline, per-language status.
- `BIBLE_IMPORT_NOTES.md` — how the offline Bible dataset was built,
  versification handling, known anomalies.
- `LOCALIZATION_GUIDE.md` — adding strings, translation-quality caveats.
- `FIREBASE_SETUP.md` — project setup for the remaining read-only
  Firestore content.
- `DEPLOYMENT_GUIDE.md` — build + platform-folder generation steps.
- `ACTION_WORKFLOW.md` — numbered fresh-clone-to-submittable-build path.
- `DEVELOPER_VERIFICATION_GUIDE.md` — manual feature-by-feature checks.
- `RELEASE_CHECKLIST.md` — everything that blocks store submission.
- `CONTRIBUTING.md` — code conventions, pre-commit checklist.
- `CHANGELOG.md` — session-by-session change log.
- `FINAL_AUDIT_REPORT.md` — an earlier full done/partial/not-started
  ledger, largely superseded by `PROJECT_MIGRATION_AUDIT.md` now.
- `test/README.md` — what the test suite actually covers (currently:
  very little — see "What's not done yet").
