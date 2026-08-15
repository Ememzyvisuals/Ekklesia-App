# API Reference

The Flutter client no longer calls any Firebase Cloud Function callable
directly — as of this pass, everything that used to require Cloud
Functions moved to three Cloudflare Workers, specifically to avoid
requiring the Firebase Blaze plan. See `PHASE2_NOTES.md` for the full
reasoning — Blaze is now genuinely, fully avoidable; `functions/` is
kept in the repo only as an optional rollback path.

All three Workers use the same auth model: a Firebase ID token sent as
`Authorization: Bearer <token>`, verified by the Worker itself against
Google's public JWKS (a plain Worker doesn't get `request.auth` for free
the way a Firebase callable does).

## Cloudflare Worker — Groq proxy (`cloudflare/groq-proxy/`)

### `POST {groqProxyBaseUrl}/groqChat`

**Called from**: `GroqService.chat()` (`lib/core/services/groq_service.dart`)

Request:
```json
{
  "messages": [{"role": "system", "content": "..."}, {"role": "user", "content": "..."}],
  "model": "llama-3.3-70b-versatile"
}
```

Response (200): `{"reply": "..."}`. Error shape (4xx/5xx): `{"error": "..."}`.

### `GET {groqProxyBaseUrl}/groqModels`

**Called from**: `AIConfig.verify()` (`lib/core/services/ai_config.dart`)

Response (200): `{"modelIds": ["llama-3.3-70b-versatile", "..."]}`.
`AIConfig.verify()` picks the first entry in
`AppConfig.groqSupportedModels` present in this list.

### Direct-to-Groq (bring-your-own-key path)

**Called from**: `GroqService._chatWithPersonalKey()`, when a personal
key is set in Settings (`UserGroqKeyService`). Bypasses the Worker
entirely — calls `https://api.groq.com/openai/v1/chat/completions`
directly with the user's own key. Legitimate exception to "never call
external APIs directly" since it's the user's own revocable credential,
not a shared secret — see `groq_service.dart`'s doc comment.

## Cloudflare Worker — YouTube sync (`cloudflare/youtube-sync/`)

### `POST {youtubeSyncProxyBaseUrl}/syncNow`

**Called from**: `YoutubeRepository.refresh()` (`lib/features/sermons/data/youtube_repository.dart`)

Request: no body, just the auth header.

Response (200): `{"videos": <count>, "live": <bool>}`. The client
currently ignores this body and just treats a non-throwing 200 as
success, then relies on its Firestore listeners
(`getCachedUploads`/`watchLiveStatus`) to pick up the new data — same
pattern as when this was a Firebase callable.

This Worker also runs on a Cloudflare Cron Trigger every 15 minutes
(`wrangler.toml`), independent of any client being open — replacing
`youtubeSyncSchedule`. Unlike the Groq proxy, this Worker also writes to
Firestore itself (via a real Google Service Account — see
`cloudflare/youtube-sync/README.md`), since `firestore.rules` blocks
client writes to `youtube_videos`/`config` by design and this migration
didn't relax that. It also detects the not-live -> live transition
inline and sends a push notification at that point — replacing
`onLiveStatusChanged` (a Firestore trigger, which has no Workers
equivalent — see `youtube.ts`).

## Cloudflare Worker — daily content (`cloudflare/daily-content/`)

**Not called by the Flutter client at all** — this Worker is purely
server-side, driven by its own three Cron Triggers. Its `fetch()` routes
exist only for manual testing (curl + a real Firebase ID token, same
pattern as the other two Workers):

| Endpoint | Cron equivalent | Replaces |
|---|---|---|
| `POST {dailyContentBaseUrl}/verseNow` | `5 23 * * *` (00:05 Africa/Lagos) | `dailyVerseSchedule` + `onDailyVerseCreated` |
| `POST {dailyContentBaseUrl}/prayerNow` | `10 23 * * *` (00:10 Africa/Lagos) | `dailyPrayerSchedule` + `onDailyPrayerCreated` |
| `POST {dailyContentBaseUrl}/cleanupNow` | `35 23 * * *` (00:35 Africa/Lagos) | `cleanupSchedule` |

Each of the verse/prayer jobs sends its push notification inline, right
after writing the Firestore doc, using FCM's HTTP v1 API — see
`cloudflare/daily-content/README.md`'s "why this needed actual research"
section for why that replaces the Firestore-triggered notification
functions better than a mechanical port would have.

## Firebase Cloud Functions — fully superseded, kept only as a rollback path

Every function in `functions/src/` — `groqProxy.ts`, `youtubeSync.ts`,
`dailyVerse.ts`, `dailyPrayer.ts`, `cleanup.ts`, `notifications.ts` — is
superseded by the three Cloudflare Workers above as of this pass. The
source is left in the codebase, unexported/unused, in case you'd rather
run any of it instead, or roll back a misbehaving Worker. Nothing in the
Flutter client calls any of it. See `PHASE2_NOTES.md` for the full
migration history.

## Error handling convention

Cloudflare Worker calls check `response.statusCode` directly rather than
catching a typed exception (there's no `FirebaseFunctionsException`
equivalent for a plain HTTP call). Both ultimately surface a plain
`Exception` (or `Result.failure(AppFailure(...))` for repositories using
the `Result<T>` pattern) up to the UI layer — see
`lib/core/shared/result.dart`'s doc comment for which services use
`Result<T>` vs. throwing directly (inconsistent by design, not yet
unified — see that file for the reasoning).
