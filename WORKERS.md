# Workers

See `SYSTEM_ARCHITECTURE.md`'s "Background work" section first — these
are session-scoped singleton classes triggered from `main.dart`, not real
OS background jobs. All live in `lib/core/services/*_worker.dart` unless
noted.

| Worker | Runs | Does |
|---|---|---|
| `SyncWorker` | App launch | General Firestore sync bootstrap. |
| `YoutubeWorker` | App launch | Calls `YoutubeRepository.refresh()` → `youtube-sync` Cloudflare Worker's `/syncNow` (migrated off direct API calls, then off the `syncYoutubeNow` Cloud Function). |
| `ProgramWorker` | App launch / Home screen | Determines current live/upcoming/recent program for the Home card. |
| `VerseWorker` | App launch | Ensures today's verse doc exists — reads from the offline `BibleRepository` for English text (see its own doc comment), falls back gracefully if that language isn't imported yet on-device. |
| `PrayerWorker` | App launch, after VerseWorker | Generates today's prayer from the verse via `GroqService` (now backed by the `groq-proxy` Cloudflare Worker). |
| `NotificationWorker` | App launch | Local notification scheduling/registration. |
| `ConversationWorker` | AI screen | Conversation history sync/cache. |
| `CleanupWorker` | App launch | Housekeeping: prunes old log/notification docs, orphaned temp download files, **and** (added this pass) reconciles the Bible chapter-audio cache — see its own doc comment for why that's folded in here instead of a separate `BibleCleanupWorker` class. |
| `DownloadWorker` | Downloads screen | Queue/pause/resume/retry for saved audio. |

## Bible-specific "workers" that don't exist as separate classes

The original spec lists `BibleImportWorker`, `BibleIndexWorker`,
`BibleSyncWorker`, `BibleCleanupWorker`, `BibleStatisticsWorker`,
`BibleSearchWorker`, `BibleTTSWorker`. None of these exist as standalone
classes. What actually covers each responsibility:

| Spec worker | Actually implemented as |
|---|---|
| `BibleImportWorker` | `BibleImporter.importLanguage()` — called directly from a button tap in `bible_screen.dart`, not a managed/retrying background job. |
| `BibleIndexWorker` | Not separate — `normalizedText` indexing happens inline during import. |
| `BibleSyncWorker` | N/A — the Bible dataset is bundled, not synced from a server. |
| `BibleCleanupWorker` | Folded into `CleanupWorker` (see above). |
| `BibleStatisticsWorker` | Partially — `BibleAnnotationsRepository.getStreak()` and `BibleAudioCache.totalCachedBytes()` exist as repository methods, not a dedicated worker/screen. |
| `BibleSearchWorker` | N/A — `BibleRepository.search()` is a direct, synchronous-enough Isar query; no background indexing job needed at this data size. |
| `BibleTTSWorker` | Partially — `BibleTTSQueue` (`lib/features/bible/data/bible_tts_queue.dart`) does real look-ahead prefetching (chunk N+1 generates while chunk N plays), plus `TtsService.synthesizeWithRetry` and `TtsErrorLogger` handle retry/backoff/logging for cold starts and rate limits. Still not a standalone background worker class — it's a queue object created per "Listen" tap, not something with its own lifecycle/retry-across-sessions. |

This is a deliberate set of engineering calls, not an oversight — several
of the spec's named workers would be thin wrappers around one existing
method with no real added value (retry logic, scheduling, or recovery)
at the current scale. If retry/backoff/offline-queueing behavior is
actually needed for imports specifically (e.g. flaky connections during
a 30MB-ish per-language download if that ever moves off bundled assets),
that's the concrete trigger for building a real `BibleImportWorker`.
