# Offline Engine

There is one real offline-first engine in this app: the **Bible feature**.
Everything else has partial offline behavior (Firestore's built-in local
cache/persistence) but no dedicated local-first architecture.

## What's actually offline-first (Bible)

- Data: bundled per-language JSON (`assets/bible/*.json`) → imported once
  into Isar → all reads (`BibleRepository`) come from Isar, zero network
  calls, zero API.
- Search: `BibleRepository.search()` — Isar-indexed substring search over
  `normalizedText`, fully local.
- Bookmarks, highlights, notes, reading progress, reading streak — all
  Isar-backed (`bible_annotations_schema.dart`), fully local.
- Chapter audio — generated once via a network call (TTS Space), then
  cached to local disk (`BibleAudioCache`) keyed by a hash of the chapter
  text. Repeat plays are 100% local/offline after the first generation.

## What's NOT offline-first (everything else)

- Bookmarks (non-Bible), AI conversation history, notifications, download
  metadata (via SharedPreferences, not Isar — see
  `download_repository.dart`'s doc comment), daily verse/prayer, YouTube
  cache — all Firestore-backed. Firestore's SDK does provide its own local
  cache/persistence layer, so short network gaps mostly don't break the
  UI, but this isn't a deliberate local-first design the way Bible is —
  it's Firestore's default behavior.
- Radio streaming obviously requires a live connection (it's a stream).
- Sermon video playback via YouTube Player requires connectivity except
  for whatever's been explicitly saved through Downloads.

## Cache invalidation

The one place this matters concretely: Bible audio cache uses a
content-hash of the chapter's verse text (`BibleAudioCache.hashFor`), not
just a book/chapter key. If the underlying Bible data is ever corrected
(re-import with fixed text — see `BIBLE_IMPORT_NOTES.md`'s anomaly list),
the hash won't match and the stale audio is regenerated automatically
rather than silently played forever.

## Honest gap vs. the original spec

The spec describes a much broader offline engine — caching Programs,
Messages, Settings, Theme, Language, Downloads-metadata, and AI
conversations all through one unified local-first layer with background
sync reconciliation. That doesn't exist. What exists is: Bible is fully
local-first (Isar), everything else relies on Firestore's own offline
persistence with no additional local-first layer on top. Building the
broader version would mean either extending Isar to cover those
collections too, or explicitly documenting Firestore's offline
persistence settings and treating that as "good enough" — that decision
hasn't been made, just flagged here so it doesn't get silently assumed
either way.
