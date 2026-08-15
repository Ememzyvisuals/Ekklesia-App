# Cloud Functions

> **DELETED (PROJECT_MIGRATION_AUDIT.md).** `functions/src/` no longer
> exists in this repository. It was already fully superseded by
> Cloudflare Workers (see below) — and those Workers have since been
> deleted too, by explicit instruction that this app runs no cloud
> infrastructure of its own at all. Kept here as a historical record of
> what this code used to do, not as a setup guide — there is nothing
> left to deploy or roll back to.

Source: `functions/src/`. All deployed to `us-central1`. **Every function
below is superseded by a Cloudflare Worker as of this pass** — see
`PHASE2_NOTES.md`. Deploying this directory is entirely optional now, kept
only as a manual rollback path; nothing in the Flutter client calls any
of these. See `FIREBASE_SETUP.md` if you do choose to deploy it anyway.

| File | Exports | Type | Purpose |
|---|---|---|---|
| `dailyVerse.ts` | `dailyVerseSchedule` | Scheduled (daily), **superseded** | Picks and stores today's verse reference + English text in `daily_verse/{yyyy-MM-dd}`. Replaced by `cloudflare/daily-content/`'s `5 23 * * *` Cron Trigger, which also sends the push notification inline (see that Worker's `dailyVerse.ts`). |
| `dailyPrayer.ts` | `dailyPrayerSchedule` | Scheduled (daily, after verse), **superseded** | Generates a short prayer from today's verse via Groq, stores in `daily_prayer/{yyyy-MM-dd}`. Replaced by `cloudflare/daily-content/`'s `10 23 * * *` Cron Trigger. |
| `youtubeSync.ts` | `youtubeSyncSchedule`, `syncYoutubeNow` | Scheduled + Callable, **superseded** | Replaced by `cloudflare/youtube-sync/`'s `/syncNow` endpoint + its own Cron Trigger, which also detects the live-status transition and sends that push inline (see that Worker's `youtube.ts`). |
| `groqProxy.ts` | `groqChat`, `groqModels` | Callable, **superseded** | Replaced by `cloudflare/groq-proxy/`. |
| `groq.ts` | (internal helper) | — | Defines the `GROQ_API_KEY` secret and the actual Groq API call used by `groqProxy.ts`. |
| `bibleText.ts` | `fetchEnglishVerseText` (helper, imported by `dailyVerse.ts`) | — | Fetches a single English verse's text from the wldeh CDN server-side, for the daily-verse doc only. This is unrelated to the client's offline Bible engine (`lib/features/bible/`) — that reads from a bundled dataset, not any API. Confirmed still actively imported (not dead code) — verify this before ever assuming it's safe to remove. Ported to `cloudflare/daily-content/src/bibleText.ts` with the same logic, native `fetch` instead of `node-fetch`. |
| `notifications.ts` | Firestore-triggered functions | Trigger, **superseded** | Fanned out push notifications on relevant writes. Firestore triggers don't exist on Workers — replaced not with a direct port but with the notification being sent inline, in the same Worker call that makes the write it used to react to. See `cloudflare/daily-content/README.md`'s "why this needed actual research" section. |
| `cleanup.ts` | `cleanupSchedule` | Scheduled, **superseded** | Server-side pruning of old log/notification documents — the server-side counterpart to the client's `CleanupWorker`. Replaced by `cloudflare/daily-content/`'s `35 23 * * *` Cron Trigger. |
| `config.ts` | shared constants | — | Region, collection names, etc. shared across function files. |
| `index.ts` | re-exports everything above | — | The actual deploy manifest — `firebase deploy --only functions` deploys whatever this file exports, if you choose to deploy it at all. |

## Client callers

| Endpoint | Called from (client) |
|---|---|
| `groqChat` (Cloudflare Worker) | `lib/core/services/groq_service.dart` → `GroqService.chat()` |
| `groqModels` (Cloudflare Worker) | `lib/core/services/ai_config.dart` → `AIConfig.verify()` |
| `syncNow` (Cloudflare Worker, `cloudflare/youtube-sync/`) | `lib/features/sermons/data/youtube_repository.dart` → `YoutubeRepository.refresh()` |

None of the Firebase Cloud Functions above are called by the client
anymore as of this pass, and (unlike an earlier pass) that's no longer a
partial migration — see `PHASE2_NOTES.md`: Blaze is now genuinely fully
avoidable, since `cloudflare/daily-content/` closed the remaining gap.
That Worker isn't in the table above because it isn't called by the
client at all — it's driven entirely by its own Cron Triggers; see
`API_REFERENCE.md` for its endpoints (manual-testing only).

## Not yet migrated

Nothing else client-side calls an external API directly with a bundled
key at this point — the Groq and YouTube migrations (this pass) were the
two flagged in `PHASE2_NOTES.md`. If a future feature needs a new
external API, follow the same pattern: Secret Manager + callable, never a
key in `.env`/`.env.example`.
