# Phase 2 — Cloud Functions backend

Adds the server-side half of the spec's "Flutter -> Firebase Auth -> Cloud
Functions -> External APIs -> Firestore -> Flutter" architecture. Everything
below is real, type-checked TypeScript (`npx tsc --noEmit` passes clean,
`npm run build` produces working `lib/`) — not scaffolding.

## What's here

| Function | Trigger | Does | Status |
|---|---|---|---|
| `dailyVerseSchedule` | Cloud Scheduler, 00:05 Africa/Lagos daily | Picks today's reference, fetches English text from wldeh's CDN, writes `daily_verse/{yyyy-MM-dd}` | **Superseded** — `cloudflare/daily-content/`'s `5 23 * * *` Cron Trigger |
| `dailyPrayerSchedule` | Cloud Scheduler, 00:10 Africa/Lagos daily | Reads today's verse, asks Groq for a short prayer, writes `daily_prayer/{yyyy-MM-dd}` | **Superseded** — `cloudflare/daily-content/`'s `10 23 * * *` Cron Trigger |
| `youtubeSyncSchedule` | Cloud Scheduler, every 15 min | Mirrors `YoutubeRepository.refresh()` server-side — writes `youtube_videos/*` and `config/youtube_live_status` | **Superseded** — `cloudflare/youtube-sync/`'s own Cron Trigger |
| `groqChat` / `groqModels` | Callable | Groq chat/model-list proxy | **Superseded** — `cloudflare/groq-proxy/` |
| `onDailyVerseCreated` / `onDailyPrayerCreated` / `onLiveStatusChanged` | Firestore triggers | Fan out FCM pushes + write per-user `notifications` docs | **Superseded** — folded inline into `cloudflare/daily-content/` and `cloudflare/youtube-sync/` respectively (see below for why) |
| `cleanupSchedule` | Cloud Scheduler, every 24h | Prunes `notifications`/`worker_logs`/`sync_logs`/`download_logs` across **all** users (client-side `CleanupWorker` only ever prunes whoever's currently signed in on that device) | **Superseded** — `cloudflare/daily-content/`'s `35 23 * * *` Cron Trigger |
| `generateTodaysVerseNow` / `syncYoutubeNow` | Callable | Manual triggers for testing without waiting on the schedule | **Superseded** — `/verseNow`, `/syncNow` on the respective Workers |

Every function in this table is superseded as of this pass — see
"Where things actually stand now" below. `functions/` is kept in the
repo, type-checked and buildable, purely as a rollback option.

`src/config.ts` mirrors `app_config.dart`'s collection name constants by hand
— there's no cross-language codegen in this repo, so if you rename a
collection in `app_config.dart`, update `functions/src/config.ts` in the
same commit.

## Groq key-exposure fix — DONE (client-side, an earlier pass)

**Superseded by the Cloudflare migration below** — kept here as history
of how the key-exposure problem was first closed, before moving off
Firebase Cloud Functions entirely for this specific piece.

`groq_service.dart` and `ai_config.dart` used to call the
`groqChat`/`groqModels` callables via `cloud_functions` instead of
holding `GROQ_API_KEY` through `flutter_dotenv`. `GROQ_API_KEY` was
removed from `.env.example` at that point — it never went back in.

## Groq moved off Firebase entirely — Cloudflare Workers (this pass)

`groqChat`/`groqModels` are no longer called by the client at all.
`GroqService`/`AIConfig` now call a Cloudflare Worker
(`cloudflare/groq-proxy/`) instead — same job (hide the Groq key,
verify the caller is a real signed-in user), different host, because
Firebase Cloud Functions require the Blaze plan (a payment method on
file) even for a single lightweight callable, and Cloudflare Workers'
free tier needs none. See `cloudflare/groq-proxy/README.md` for the
full reasoning, verified current free-tier numbers, and deploy steps.

**`functions/src/groqProxy.ts` and `functions/src/groq.ts` are left in
place, unexported changes** — not deleted, in case you'd rather run both
or roll back, but nothing in the Flutter client calls them anymore.

**YouTube sync has ALSO now moved off Firebase this same pass** (see the
next section) — see that section for the honest remaining-Blaze-surface
caveat.

## YouTube sync also moved off Firebase — Cloudflare Workers (this pass)

Same reasoning as Groq above. `YoutubeRepository.refresh()` now calls
`cloudflare/youtube-sync/`'s `/syncNow` endpoint instead of the
`syncYoutubeNow` callable. That Worker also handles the 15-minute
schedule itself via a Cloudflare Cron Trigger, replacing
`youtubeSyncSchedule`. It writes to Firestore using a real Google
Service Account (not by relaxing `firestore.rules`) — see
`cloudflare/youtube-sync/README.md`, which also flags this as the
riskiest, least-conventional piece of the whole project (hand-rolled
service-account OAuth2 in a Workers runtime, untested against a real
account).

**`cloud_functions` is now a fully unused dependency and was removed
from `pubspec.yaml`** — nothing in the Flutter client calls any Firebase
callable anymore.

## Daily verse/prayer/cleanup + all remaining notification fan-out — moved off Firebase too (this pass)

Closing the honesty gap this file used to flag right here: after Groq and
YouTube sync, `dailyVerseSchedule`, `dailyPrayerSchedule`,
`cleanupSchedule`, and the three Firestore-triggered notification
functions (`onDailyVerseCreated`, `onDailyPrayerCreated`,
`onLiveStatusChanged`) were still Blaze-only, since deploying
`functions/` at all requires it regardless of which specific functions
you actually use. All four are now covered:

- `dailyVerseSchedule` + `onDailyVerseCreated`,
  `dailyPrayerSchedule` + `onDailyPrayerCreated`, and
  `cleanupSchedule` → a new Worker, `cloudflare/daily-content/`, with
  three Cron Triggers (Workers Free plan allows up to 3 per Worker —
  exactly enough).
- `onLiveStatusChanged` → folded into `cloudflare/youtube-sync/`'s
  existing sync job, since it already writes the doc that trigger used
  to react to (see that Worker's `youtube.ts`/`fcm.ts`, updated this
  pass).

The Firestore-trigger functions specifically needed real research, not
just a mechanical port — Workers has no equivalent of "react to a
document being created." The fix that came out of checking FCM's HTTP
v1 API docs: since the code writing a doc and the code that needs to
notify about it already run in the same Worker invocation, there's no
reason to route through a Firestore trigger at all — just send the push
directly after the write succeeds, using the same service-account OAuth2
pattern already built for Firestore access, with FCM's own messaging
scope. See `cloudflare/daily-content/README.md`'s "Why this needed
actual research" section for the full reasoning and what didn't work
(a polling Worker was the first idea considered, and rejected — see that
README for why).

## Where things actually stand now: Blaze genuinely is avoidable

With all five pieces (Groq, YouTube sync, daily verse/prayer, cleanup,
all notification fan-out) migrated, **`functions/` no longer needs to be
deployed for anything the Flutter client uses.** `functions/src/*.ts` is
left in place — type-checked, buildable, not deleted — in case you'd
rather run the Cloud Functions versions instead, or roll back a Worker
that misbehaves in production. But nothing in this repo requires you to
deploy it anymore.

Firebase itself (Auth, Firestore, Storage, Cloud Messaging, Analytics,
Crashlytics) was always on the free Spark plan regardless — only Cloud
Functions ever required Blaze. So the honest current statement is: **you
never need to touch the Blaze plan for this app**, full stop, not just
"you can defer it."

**What's still genuinely unverified**, same caveat repeated in every
Worker's own README: none of `cloudflare/groq-proxy/`,
`cloudflare/youtube-sync/`, or `cloudflare/daily-content/` have been
tested against a real deployed Cloudflare account, a real GCP service
account, or a real Firebase project — there's no live infrastructure in
this sandbox to verify against. Deploy and test each one's manual-trigger
endpoint (`/groqChat`, `/syncNow`, `/verseNow` + `/prayerNow` +
`/cleanupNow`) before trusting any of their cron schedules unattended.



The shared Groq proxy (Cloudflare Worker now, not a Firebase callable —
see above) has a soft daily cap
(`GroqUsageService.dailyFreeLimit = 20`, local SharedPreferences counter,
not server-enforced — see that class's doc comment for why) to protect
the shared Groq key's daily quota from being exhausted by heavy users.
Once hit, `GroqService.chat()` throws `GroqUsageLimitException` **without
making a network call**, and the AI Assistant screen shows an actionable
message with a shortcut to Settings.

Settings → AI Assistant now has a "Your own Groq API key" field
(`UserGroqKeyService`, SharedPreferences). When set, `GroqService.chat()`
calls Groq directly with the user's own key instead of the shared
callable — unlimited, doesn't touch the daily counter. This is NOT a
regression on the key-exposure fix above: a personal key is the user's
own revocable credential that they typed in themselves, not a shared
secret shipped to every install.



- (Both the Groq and YouTube client-side key-exposure fixes, previously
  documented here as not-yet-done, are now done. `YoutubeRepository.refresh()`
  calls `syncYoutubeNow` instead of the deleted `YoutubeRemoteDatasource`;
  `YOUTUBE_API_KEY` is out of `.env.example`, same as `GROQ_API_KEY`. Same
  caveat applies: not tested end-to-end against a live deployed backend.)
- **Doesn't add `firebase_functions` region/App Check config** — every
  function is pinned to `us-central1` explicitly; change that if you
  provision the Firebase project in a different region.

## Setup (optional — only needed if you choose to run `functions/` instead of/alongside the Workers)

```bash
cd functions
npm install
```

Set secrets (never commit these — they're Secret Manager values, not `.env`):

```bash
firebase functions:secrets:set GROQ_API_KEY
firebase functions:secrets:set YOUTUBE_API_KEY
```

Deploy:

```bash
firebase deploy --only functions,firestore:rules,firestore:indexes
```

## Firestore rules (`firestore.rules`)

Default-deny, then opt in per collection:
- `users/{uid}`, `ai_conversations/*`, `notifications/*`, `sync_logs/*`:
  owner-only (matched against the doc's stored `uid` field, not just
  inferred from the path, so a crafted doc id can't spoof another user).
- `daily_verse`, `daily_prayer`, `programs`, `youtube_videos`, `config/*`,
  `feature_flags`: read-only for signed-in users. `daily_verse`/
  `daily_prayer` additionally allow **create** (not update) so
  `VerseWorker`/`PrayerWorker`'s client-side fallback-generation path
  still works if a Cloud Function run is ever missed — it can create
  today's doc if one doesn't exist yet, but can never overwrite what the
  Cloud Function already wrote.
- `worker_logs`, `download_logs`: create-only for signed-in users, no
  client read (operational data) — pruned server-side by `cleanupSchedule`.

## Firestore indexes (`firestore.indexes.json`)

Composite indexes for every multi-field query found in the repositories:
`ai_conversations` (uid+session_id+created_at, uid+created_at),
`notifications` (uid+created_at both directions), `youtube_videos`
(category+published_at).
