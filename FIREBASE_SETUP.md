# Firebase Setup — REMOVED

Firebase/Firestore has been removed from this app entirely. There is no
Firebase project to set up and this file's old setup steps no longer
apply — kept as a stub so old links/history don't 404.

The app is offline-first: everything that used to live in Firestore
(bookmarks, highlights, notes, reading progress/streak, notifications,
quiz results, AI conversation history, YouTube cache, the Impact Academy
message archive, and the Games/Programs catalogs) now lives in a local
Drift database or a bundled JSON asset. See:

- `OFFLINE_ENGINE.md` — the current local storage map.
- `PROJECT_MIGRATION_AUDIT.md` — the phase-by-phase migration history
  off Firebase/Isar and onto Drift.
- `assets/data/` — the bundled catalogs (`games.json`, `programs.json`,
  `messages.json`).

The only network calls left anywhere in the app are the YouTube Data API
(sermon library refresh), the Groq API (AI chat, via the Cloudflare
Worker proxy in `cloudflare/groq-proxy/`), and the live radio stream —
all opt-in / on-demand, never required for the app to open or function.
