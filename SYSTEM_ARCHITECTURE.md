# System Architecture

## Layering

Feature-first, Clean-Architecture-flavored, not strictly enforced with
separate packages — each `lib/features/<name>/` folder has:

```
<feature>/
  data/          Repositories, Isar schemas/collections, remote data sources
  domain/        Plain Dart models, business rules with no Flutter/Isar imports
  presentation/  Widgets/screens, Riverpod ConsumerWidgets
```

State management is Riverpod throughout — plain `Provider`/`StateProvider`/
`FutureProvider`, no code generation (no `riverpod_generator` annotations
in use despite it being a dev dependency — it was added but this codebase
predates/doesn't use it; hand-written providers are the actual pattern,
see any `*_providers.dart` file).

## Data flow

```
Widget (ConsumerWidget/ConsumerStatefulWidget)
  → reads a Provider
    → Repository (data/)
      → Isar (offline-first: Bible, and only Bible so far)
      → Firestore (everything else: verse/prayer docs, YouTube cache, bookmarks, etc.)
      → Cloudflare Worker (Groq, YouTube sync-on-demand — never the raw external API)
```

The client **never** calls Groq or the YouTube Data API directly anymore —
both went through a security migration (see `PHASE2_NOTES.md`), first onto
Cloud Function callables (`groqChat`, `groqModels`, `syncYoutubeNow`), then
off Firebase entirely onto three Cloudflare Workers (`cloudflare/groq-proxy/`,
`cloudflare/youtube-sync/`, `cloudflare/daily-content/`) to avoid requiring
the Blaze plan. Each Worker verifies the caller's Firebase ID token itself
(against Google's public JWKS) since it doesn't get `request.auth` for
free the way a callable does. `dailyVerseSchedule`/`dailyPrayerSchedule`/
`cleanupSchedule` are superseded by `daily-content`'s three Cron Triggers,
and `youtubeSyncSchedule` by the YouTube Worker's own Cron Trigger —
`functions/` is fully optional now, kept only as a rollback path.

## Storage: two systems, not one

This is worth being explicit about because it's a real architectural
seam, not an oversight:

- **Isar** (`lib/core/services/isar_service.dart`) — used **only** by the
  Bible feature (`lib/features/bible/data/*_schema.dart`). Fully offline,
  no network dependency once a language is imported. This is the newer
  pattern (added this pass) and the one future offline-heavy features
  should probably follow.
- **Firestore** — used by everything else (Downloads' metadata via
  SharedPreferences actually — see `download_repository.dart`'s own doc
  comment for why that one's the odd one out — Bookmarks, Notifications,
  AI conversation history, YouTube cache, daily verse/prayer).

There's no single "offline engine" spanning both — Bible works fully
offline after import; most other features need Firestore reachability
(with Firestore's own built-in offline persistence providing some
resilience, not a custom local-first layer like Bible has).

## Background work: two different mechanisms

- **Client-side "workers"** (`lib/core/services/*_worker.dart`) — not
  real OS-level background workers (no `workmanager` scheduling actually
  wired up despite being in `pubspec.yaml`). They're singleton classes
  with a `start()`/`runOnce()` method called from `main.dart` at app
  launch, doing their job once per session (check Firestore, generate
  if missing, cache locally). Real background execution while the app is
  closed depends entirely on the Cloud Functions side.
- **Cloud Functions Scheduled + Callable** — the actual background
  execution layer. See `CLOUD_FUNCTIONS.md`.

## Localization

`flutter_localizations` + ARB files (`lib/l10n/app_*.arb`), generated via
`flutter gen-l10n` (see `l10n.yaml`) into `lib/l10n/generated/` (not
committed — build-time artifact). 5 languages: en, yo, ha, ig, pcm. See
`LOCALIZATION_GUIDE.md`.

## Where to look for what

| Concern | Location |
|---|---|
| App bootstrap / service init order | `lib/main.dart` |
| Cross-cutting config (URLs, collection names, feature flags) | `lib/core/config/app_config.dart` |
| Result/error handling convention | `lib/core/shared/result.dart` (see its own doc comment — inconsistently applied, by design, see the comment) |
| Offline Bible engine | `lib/features/bible/` + `BIBLE_IMPORT_NOTES.md` |
| Backend | `functions/src/` + `CLOUD_FUNCTIONS.md` |
