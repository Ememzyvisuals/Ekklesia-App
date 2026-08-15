# Contributing

Solo/small-team project conventions — lightweight, not a formal OSS
process.

## Before writing code

1. Read `README.md` and `FINAL_AUDIT_REPORT.md` for current state —
   don't assume a feature is done or missing without checking.
2. If touching the Bible feature, read `BIBLE_IMPORT_NOTES.md` first —
   the versification/anomaly handling is easy to break by assuming
   line-count-per-verse always holds.
3. If touching anything Groq/YouTube-related, read `PHASE2_NOTES.md` —
   both went through a client-side API-key-exposure fix; don't
   reintroduce a direct-to-API call with a bundled key.

## Code conventions

- Feature-first folders: `data/`, `domain/`, `presentation/` — see
  `SYSTEM_ARCHITECTURE.md`.
- Riverpod, hand-written providers (no codegen) — match the existing
  `*_providers.dart` pattern in whichever feature you're touching.
- No placeholder/TODO/mocked implementations — if something's
  genuinely out of scope for a change, document it explicitly (a doc
  comment explaining the gap) rather than leaving a TODO marker or fake
  stub. See any `*_worker.dart` file's doc comments for the style this
  repo already uses.
- Localize every user-facing string — see `LOCALIZATION_GUIDE.md`. Don't
  merge a screen with hardcoded English text.
- Never put an API key in `.env`/`.env.example` for a new external
  service — route it through a Cloud Function callable with the key in
  Secret Manager (see `CLOUD_FUNCTIONS.md` for the existing pattern).

## Before committing

- `dart format .`
- `flutter analyze` — fix everything it flags, don't suppress with
  `// ignore:` unless there's a specific, commented reason.
- `flutter test` — add tests for new pure-logic code (see `test/README.md`
  for what's realistic to test without a live Isar/Firebase instance).
- If you touched ARB files, confirm `test/l10n/arb_parity_test.dart`
  still passes (all 5 languages have identical key sets).

## Commit messages

No enforced format — be specific about *what* and *why*, not just *what*.
"Fix bug" is not acceptable; "Fix Isar composite index missing on
BibleVerseEntity.chapter, caused slow chapter loads" is.
