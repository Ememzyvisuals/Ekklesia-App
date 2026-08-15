# Bible Import Notes

How the offline Bible engine's data was built, what to trust, and what's
still open. Read this before touching `build_bible.py`, the importer, or
the bundled `assets/bible/*.json` files.

## Sources

- **English**: `Bible-kjv-master` — proper verse-numbered JSON (public
  domain KJV). Ground truth for standard versification (verse counts per
  chapter) used to validate the other four languages.
- **Yoruba / Hausa / Igbo / Nigerian Pidgin**: `*_readaloud.zip` — these are
  audio-recording scripts, not verse-numbered scripture text. Their own
  front matter states verse numbers were stripped. Critically, **one verse
  per line was preserved** even though the numbers weren't — this is what
  makes reconstruction possible at all.

## How verse numbers were reconstructed (`build_bible.py`)

For each chapter file in each of the four languages:

1. Strip the two header lines (book title, chapter number), count the
   remaining non-empty lines.
2. If that count matches KJV's verse count for the same book/chapter
   exactly → direct 1:1 mapping, line *i* = verse *i*. This covers
   **~99.7% of all 1,189 chapters per language**.
3. If it's short by exactly the chapters known to contain textual-tradition
   omissions (see `KNOWN_OMISSIONS` in `build_bible.py` — Matthew 17:21,
   18:11, 23:14; Mark 7:16, 9:44, 9:46, 11:26, 15:28; Luke 17:36, 23:17;
   John 5:4; Acts 8:37, 15:34, 24:7, 28:29; Romans 16:24), re-insert those
   verse numbers as `omitted: true` placeholders so the rest of the
   chapter's numbering stays standard instead of drifting by one. This is
   well-documented Bible textual criticism (modern critical-text
   translations vs KJV's Textus Receptus base) — not a guess specific to
   this data.
4. Anything else (translator condensed or split verses — e.g. Pidgin's
   Numbers 1, which compresses repetitive tribal-count verses) gets
   best-effort sequential numbering and is flagged `approximate: true`,
   plus logged in each language's `anomalies` array. **Fewer than 4
   chapters out of 1,189 per language hit this path.**

Run `python3 build_bible.py` (lives outside the Flutter repo, in the build
scratch space this pass — copy it back in if you need to regenerate) to
rebuild `assets/bible/*.json` + `manifest.json` from the raw uploads.

## What the app does with the flags

- `omitted` verses render as "[Not included in this translation]" instead
  of blank/missing — `bible_screen.dart`.
- `approximate` verses get a small "(approx. numbering)" inline label.
- Neither flag blocks reading, search, or bookmarking — they're
  informational only.

## Known data quality numbers (from the actual generated files)

| Language | Books | Chapters | Verses | Anomalous chapters |
|---|---|---|---|---|
| English (KJV) | 66 | 1,189 | 31,102 | 0 |
| Yoruba | 66 | 1,189 | 31,102 | 0 |
| Hausa | 66 | 1,189 | 31,102 | 0 |
| Igbo | 66 | 1,189 | 31,103 | 1 (3 John — extra line) |
| Nigerian Pidgin | 66 | 1,189 | ~31,103 | 3 (Numbers 1 condensed; 3 John, Revelation 12 — extra lines) |

Re-run `build_bible.py`'s summary output (`import_summary.json`) any time
the source files change — don't hand-edit these counts.

## Honest scope — what this pass built vs did not

**Built and real:**
- Isar schema (`bible_local_schema.dart`), importer with checksum
  verification (`bible_importer.dart`), repository with reference parsing
  + offline substring search (`bible_repository.dart`), Riverpod wiring
  (`bible_providers.dart`), `IsarService` (first real use of Isar in this
  repo — it was in `pubspec.yaml` but nothing opened it before now).
- Reader UI: language switch, per-language import gate, book → chapter →
  verse navigation, reference jump ("John 3:16"), offline full-text
  search (also surfaced in the global Search screen), verse bookmarking,
  chapter-level "Listen" via the existing TTS/Audio pipeline — with
  generated audio now cached to local disk (`bible_audio_cache.dart`,
  keyed by chapter text hash) so replaying a chapter plays instantly from
  disk instead of re-generating through the TTS Space. A text-hash check
  means if the underlying Bible data is ever corrected via re-import, the
  stale cached audio for that chapter is detected and regenerated rather
  than silently kept.
- `VerseWorker` and global search rewired off the deleted API-based
  `bible_service.dart` onto this repository.
- Verse highlights (4-color palette), verse notes, and "Continue Reading"
  (last-read position per language) — `bible_annotations_schema.dart` /
  `bible_annotations_repository.dart`, wired into `bible_screen.dart`'s
  long-press sheet and book list.

**Not built this pass — do not assume these exist:**
- Reading history/completion %, and full "reading progress" beyond a
  single last-position-per-language pointer (streak IS built — see
  `BibleAnnotationsRepository.recordReadingActivity`).
- Dedicated Bible workers (`BibleImportWorker`, `BibleIndexWorker`,
  `BibleSyncWorker`, `BibleCleanupWorker`, `BibleStatisticsWorker`,
  `BibleSearchWorker`) — import currently runs synchronously from a button
  tap, not as a managed background worker with retry/recovery. See
  `WORKERS.md` for which of these got folded into existing classes.
- `.g.dart` part files for the Isar schema — **cannot be generated in this
  sandbox** (no Flutter SDK). Run
  `flutter pub run build_runner build --delete-conflicting-outputs`

**Partially built — real, but not the full spec:**
- The chunked prefetch-while-playing TTS streaming queue is now
  **partially** implemented: `BibleTTSQueue`
  (`lib/features/bible/data/bible_tts_queue.dart`) generates chunk N+1
  while chunk N plays — real concurrency, closes the "dead air between
  chunks" gap. What's simplified vs. the spec's full seven-class design
  (`QueueManager`/`PlaybackManager`/`ChunkGenerator`/`AudioScheduler`/
  `PrefetchManager`/`RetryManager`/`PlaybackLogger`): retry lives in
  `TtsService.synthesizeWithRetry` (shared across all TTS callers, not
  Bible-specific) and logging lives in `TtsErrorLogger` — see
  `BibleTTSQueue`'s doc comment for why that's a deliberate call.
- TTS failures (cold-starting HF Space, rate limiting, timeouts) now
  retry automatically with backoff and log to Firestore's `worker_logs`
  (`TtsErrorLogger`) instead of failing silently on the first hiccup —
  see `gradio_client.dart` and `tts_service.dart`.
  before this compiles.
