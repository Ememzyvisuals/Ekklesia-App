# Tests

Run with `flutter test` (requires the Flutter SDK — see README.md's setup
steps; these tests have never actually been executed in this sandbox,
since no SDK is available here).

## What's covered

- `features/bible/bible_books_test.dart` — the canonical 66-book registry
  and name-matching logic (pure Dart, no I/O).
- `features/bible/bible_repository_test.dart` — reference parsing
  ("John 3:16" → book/chapter/verse), including error cases.
- `features/bible/bible_audio_cache_test.dart` — the content-hash function
  used to key cached chapter audio.
- `l10n/arb_parity_test.dart` — guards against exactly the kind of
  localization bug that's easy to introduce silently: editing one
  language's ARB file and forgetting the other four. Also checks valid
  JSON, no empty translation values, and `@@locale` matching the filename.

All of the above are pure-logic tests — no Isar database, no Firebase, no
widget pumping. They were chosen deliberately: they're the tests that can
be written and reasoned about with confidence without a live Flutter/Isar
runtime to execute against.

## What's NOT covered (be aware before assuming coverage)

- Anything touching Isar directly (BibleImporter, BibleRepository's actual
  query methods, BibleAnnotationsRepository, BibleAudioCache's file I/O) —
  these need a real (or in-memory/temp-dir) Isar instance to test against,
  which needs the Isar generator's `.g.dart` files to exist first (they
  don't yet in this repo — see README.md).
- Widget tests for any screen.
- Firebase-backed workers (VerseWorker, PrayerWorker, YoutubeWorker, etc.)
  — these need either a Firestore emulator or a mocking layer, neither of
  which exists here yet.
- Cloud Functions (functions/src/*.ts) — no test setup exists there
  either; that would use a separate Node/Jest (or similar) toolchain, not
  `flutter test`.

This is a real but partial start, not a finished suite — treat "no
automated tests" as still mostly true until the above gaps are closed.
