# Database Schema

Two stores — see `SYSTEM_ARCHITECTURE.md` for why they're separate.

## Isar (local, Bible feature only)

Defined across `lib/features/bible/data/*_schema.dart`. All collections
are keyed at minimum by `language` (short code: en/yo/ha/ig/pcm).

| Collection | Key fields | Purpose |
|---|---|---|
| `BibleBookEntity` | language, code, position | One row per (language, book). 66 per language once imported. |
| `BibleChapterEntity` | language, bookCode, number | One row per (language, book, chapter). |
| `BibleVerseEntity` | language, bookCode, chapter, number | One row per verse. `omitted`/`approximate` flags — see `BIBLE_IMPORT_NOTES.md`. `normalizedText` indexed for substring search. |
| `BibleImportRecordEntity` | language (unique) | Tracks whether/how a language was imported — checksum, counts, timestamp. |
| `BibleAudioCacheEntity` | language, bookCode, chapter | Local file paths for cached chapter TTS audio, keyed by a content hash of the verse text. |
| `BibleHighlightEntity` | language, bookCode, chapter, verseNumber | One highlight color per verse (re-highlighting replaces, doesn't stack). |
| `BibleNoteEntity` | language, bookCode, chapter, verseNumber | One note per verse. |
| `BibleReadingProgressEntity` | language (unique) | Last-read book/chapter per language — "Continue Reading." |
| `BibleReadingStreakEntity` | (single global row) | Cross-language daily reading streak. |

All schemas need `.g.dart` part files generated via
`flutter pub run build_runner build --delete-conflicting-outputs` before
they compile — not generated in this repo (no Flutter SDK in this
sandbox).

## Firestore (everything else)

Collection names come from `AppConfig` constants — check there for the
authoritative list; this table is a summary, not a substitute.

| Collection | Written by | Read by |
|---|---|---|
| `daily_verse` / `daily_prayer` (one doc per `yyyy-MM-dd`) | `cloudflare/daily-content/` Worker (Cron Triggers, superseded `dailyVerseSchedule`/`dailyPrayerSchedule`), with `VerseWorker`/`PrayerWorker` as a client-side fallback if the doc is missing | Home screen |
| `youtube_videos` | `cloudflare/youtube-sync/` Worker (Cron Trigger + `/syncNow`), via a Google Service Account — not a Cloud Function anymore | Sermons screen, Search |
| `config/youtube_live_status` | same as above | Home screen (live banner) |
| `users/{uid}` | AuthService on signup | Profile/Settings |
| Bookmarks, AI conversations, notifications, download logs, worker logs, sync logs | client + Cloudflare Workers (`daily-content`, `youtube-sync` — superseded the Cloud Functions fan-out triggers) | respective feature screens |

Firestore security rules are in `firestore.rules`; composite indexes in
`firestore.indexes.json`. Deploy both together — see `FIREBASE_SETUP.md`.

## What's NOT modeled yet

- No `feature_flags` collection despite it being mentioned in the master
  spec's admin-system section — nothing in this codebase reads a remote
  feature flag today.
- No `analytics` collection distinct from Firebase Analytics' own
  managed event stream.
