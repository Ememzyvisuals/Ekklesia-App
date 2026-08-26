# Ekklesia Audio Bible — packaging pipeline

Downloads pre-recorded Bible audio from verified public sources and
republishes it as GitHub Releases, structured so the Ekklesia app can
download exactly one chapter at a time.

## Sources (verified, not assumed — see the conversation this came from
for how each was checked)

- **English (KJV)**: `eliranwong/MP3_KingJamesVersion_american` — 66
  book zips, verse-level MP3s, CC BY 4.0. Verified by actually
  downloading and inspecting `01_Genesis.zip`: 50 chapter folders
  (`1_1/` … `1_50/`), correct verse counts, files named
  `KJV_{book}_{chapter}_{verse}.mp3`.
- **Yoruba, Igbo, Hausa**: `AfriSpeech/open-bible-speech-african` on
  Hugging Face — verse-level audio + text, CC BY-SA 4.0. Verified by
  directly fetching the dataset page (not just search) — real data,
  real audio URLs, columns: `audio, text, testament, book, chapter,
  verse, duration_seconds, speaker_id`.
- **Pidgin**: no open, full-Bible audio source found. Not included.
- **Igbo audio**: newly possible via this dataset (an earlier pass in
  this project incorrectly assumed Igbo had no audio source at all —
  it does, via AfriSpeech).

## Where this lives

This is part of the main Ekklesia repo, in its own `audio_bible/`
folder — separate from the Flutter app's `lib/` code, and with its own
workflow files (`.github/workflows/audio-bible-english.yml`,
`.github/workflows/audio-bible-african.yml`). Both are
`workflow_dispatch`-only (manually triggered from the Actions tab,
never on a push or tag), so they can never interfere with or be
triggered by the app's own `release.yml` build pipeline — the two are
fully independent even though they share a repo.

## Setup

No extra secrets needed — both workflows use the automatically-
provided `GITHUB_TOKEN`, which already has permission to create
releases in this repo.

## Running it

Both workflows are manual (`workflow_dispatch`) — go to the repo's
Actions tab, pick the workflow, and run it with inputs.

**Start small on both, on purpose**: neither workflow has been run
for real yet. The English zip-repackaging logic *was* tested against
real downloaded data in the session that wrote this (see
`scripts/package_english.py`'s and `book_list.py`'s own comments for
exactly what was verified), but the actual GitHub Actions execution
environment, the `gh release` calls, and the entire African-language
dataset-loading path have not been. Recommended first runs:

```
Package English (KJV) Audio Bible → book_numbers: "1"
Package African-Language Audio Bibles → languages: "Yoruba"
```

Check the Actions log carefully after each. For the African workflow
specifically, watch for `::warning::` lines about unmapped book
names — if the dataset uses a book-name spelling `book_list.py` doesn't
recognize, those verses get silently skipped rather than misfiled, and
you'd want to add an alias in `scripts/book_list.py`'s `_ALIASES` dict
and re-run that one book/language before scaling up.

Once a small run looks correct (check the release that gets created —
does it have chapter zips, do a couple sound right when downloaded and
played?), scale up:

```
Package English (KJV) Audio Bible → book_numbers: "all"
Package African-Language Audio Bibles → languages: "Yoruba,Igbo,Hausa"
```

## What the app will need to know

- Release tag format: `{lang}-{book_number:02d}-{book_slug}`
  (e.g. `en-01-genesis`, `yo-19-psalms`, `ha-40-matthew`).
- Asset filename format: `{lang}_{book_slug}_{chapter}.zip`
  (e.g. `en_genesis_1.zip`).
- Download URL pattern:
  `https://github.com/{owner}/{repo}/releases/download/{tag}/{asset}`
- Each chapter zip contains flat verse audio files (no subfolders) —
  `KJV_{book}_{chapter}_{verse}.mp3` for English,
  `{lang}_{slug}_{chapter}_{verse}.wav` for the African languages.
- `scripts/book_list.py`'s `BOOKS` list is the canonical book
  numbering/slugging — the app-side download code should use the same
  66-book list (or import/mirror it) so book numbers always agree with
  what's actually published here.
