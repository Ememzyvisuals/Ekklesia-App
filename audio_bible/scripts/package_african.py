"""Loads one language subset of AfriSpeech/open-bible-speech-african,
groups verses by (book, chapter), and creates/updates a GitHub Release
per book with one zip per chapter as an asset — same naming scheme as
package_english.py so the app can request a chapter the same way
regardless of language.

Usage: python3 package_african.py <language-config-name> <lang-code>
  e.g. python3 package_african.py Yoruba yo

Requires: GITHUB_TOKEN, and the `datasets`/`huggingface_hub` packages
installed (see the workflow's pip install step).

IMPORTANT — unlike package_english.py, the dataset-loading and audio-
extraction logic below has NOT been executed against the real dataset
in this session: huggingface.co isn't reachable from the sandbox this
was written in, only from GitHub Actions' own runners. It's written
carefully against the schema actually confirmed by directly fetching
https://huggingface.co/datasets/AfriSpeech/open-bible-speech-african
(columns: audio, text, testament, book, chapter, verse,
duration_seconds, speaker_id; audio field is WAV per the sample CDN
URLs seen ending in "/audio/audio.wav"), but treat its FIRST real run
as a real test, not a formality — check the Actions log carefully,
especially the "unmapped book name" warnings this script prints for
any book string book_list.py's slug_for_book_name() doesn't recognize.
"""
import argparse
import subprocess
import sys
import time
import zipfile
from collections import defaultdict
from pathlib import Path

from book_list import BOOKS, slug_for_book_name, release_tag, chapter_asset_name


def gh(*args: str) -> subprocess.CompletedProcess:
    # See package_english.py's identical fix for why this matters — the
    # same error-hiding bug existed here too.
    try:
        return subprocess.run(
            ["gh", *args], check=True, capture_output=True, text=True
        )
    except subprocess.CalledProcessError as e:
        print(f"::error::gh {' '.join(args)} failed (exit {e.returncode})")
        if e.stdout:
            print(f"--- gh stdout ---\n{e.stdout}")
        if e.stderr:
            print(f"--- gh stderr ---\n{e.stderr}")
        raise


def ensure_release(tag: str, title: str) -> set[str]:
    """Creates the release if it doesn't exist yet, and returns the set
    of asset filenames it ALREADY has (empty set for a brand new
    release).

    Real, confirmed problem this fixes: the first version of this
    function returned nothing, and the main loop below always
    re-created every chapter zip and re-uploaded it regardless of
    whether it was already there. Confirmed on a real run — hitting
    GitHub's API rate limit (`HTTP 403: API rate limit exceeded`)
    partway through a language, with hundreds of chapters already
    successfully uploaded, meant a straightforward re-run would burn
    through the SAME rate limit again re-uploading all that already-
    correct work before ever reaching new ground — wasteful at best,
    and likely to hit the same rate limit again even sooner. Returning
    the existing asset list lets the main loop skip anything already
    present.
    """
    result = subprocess.run(
        ["gh", "release", "view", tag, "--json", "assets",
         "-q", ".assets[].name"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        gh("release", "create", tag, "--title", title, "--notes",
           f"Chapter-by-chapter audio Bible assets ({title}).")
        print(f"Created release {tag}")
        return set()
    else:
        existing = set(line for line in result.stdout.splitlines() if line)
        print(f"Release {tag} already exists — reusing it "
              f"({len(existing)} assets already uploaded)")
        return existing


def upload_asset(tag: str, asset_path: Path) -> None:
    gh("release", "upload", tag, str(asset_path), "--clobber")
    # A deliberate, small throttle — not required for correctness, but
    # real evidence (see ensure_release's doc comment) that hammering
    # the release API as fast as possible across many hundreds of
    # chapters can trip GitHub's rate limiting. A person's whole Bible
    # is not an emergency; trading some wall-clock time for staying
    # comfortably under the limit is a good trade here.
    time.sleep(0.5)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("config_name", help='e.g. "Yoruba", "Igbo", "Hausa"')
    parser.add_argument("lang_code", help='e.g. "yo", "ig", "ha"')
    args = parser.parse_args()

    # Imported here, not at module level, so book_list.py's tested logic
    # (see the test run against real book names) can be imported and
    # unit-tested without requiring `datasets` to be installed.
    from datasets import Audio, concatenate_datasets, load_dataset

    print(f"Loading AfriSpeech/open-bible-speech-african config "
          f"'{args.config_name}' (both splits)...")
    ds_train = load_dataset(
        "AfriSpeech/open-bible-speech-african", args.config_name, split="train"
    )
    try:
        ds_test = load_dataset(
            "AfriSpeech/open-bible-speech-african", args.config_name, split="test"
        )
        dataset = concatenate_datasets([ds_train, ds_test])
    except (ValueError, KeyError):
        # Not every config may have a "test" split — fall back to train
        # only rather than failing the whole run over a missing split.
        print("No separate 'test' split for this config — using 'train' only.")
        dataset = ds_train

    # Real bug caught and fixed before this was ever run: without this
    # cast, the `datasets` library auto-DECODES the audio column into
    # `{'array': np.ndarray, 'sampling_rate': int, ...}` — there is no
    # `bytes` key at all in that form, so `audio["bytes"]` below would
    # throw a KeyError on the very first row. `decode=False` keeps the
    # raw, original-format bytes instead, which is exactly what's
    # wanted here (write the original WAV bytes straight to disk, no
    # re-encoding, no numpy/soundfile dependency needed).
    dataset = dataset.cast_column("audio", Audio(decode=False))

    print(f"Loaded {len(dataset)} rows total.")

    # Real, confirmed bug fixed here: the first version of this script
    # iterated the WHOLE dataset up front, pulling every row's audio
    # bytes into one big in-memory `groups` dict before writing a
    # single zip. Confirmed on a real run — Yoruba and Igbo both loaded
    # both splits successfully (visible in the Actions log, 100% on
    # both progress bars), then the job died immediately after with no
    # Python traceback at all — the classic signature of the OS
    # OOM-killing the process outright (a real Python exception would
    # have shown a traceback; an OS kill just stops everything, which
    # GitHub Actions reports as "the operation was canceled").
    # ~30,000 verses' worth of decoded audio held in memory
    # simultaneously, on top of whatever the `datasets`/`pyarrow`
    # library itself holds, is a very plausible way to exceed a
    # standard GitHub-hosted runner's ~7GB RAM.
    #
    # Fixed with a genuine two-pass, low-memory design:
    #   Pass 1 (cheap): iterate a version of the dataset with the
    #     `audio` column REMOVED, to build the (book, chapter) -> list
    #     of row-index groupings without ever touching audio bytes.
    #   Pass 2: for each (book, chapter) group, fetch ONLY that
    #     group's rows (typically 10-30 verses) via `dataset.select()`,
    #     zip them, upload, and let Python garbage-collect that small
    #     batch before moving to the next chapter. Peak memory is now
    #     roughly "one chapter's worth of audio," not "the entire
    #     language's audio," regardless of how many verses the whole
    #     dataset has.
    print("Pass 1/2: grouping verses by (book, chapter) — metadata only, "
          "no audio touched yet...")
    metadata_only = dataset.remove_columns(["audio"])
    groups: dict[tuple[str, int], list[tuple[int, int]]] = defaultdict(list)
    unmapped_books: set[str] = set()

    for row_index, row in enumerate(metadata_only):
        raw_book = row["book"]
        slug = slug_for_book_name(raw_book)
        if slug is None:
            unmapped_books.add(raw_book)
            continue
        try:
            chapter_number = int(row["chapter"])
            verse_number = int(row["verse"])
        except (TypeError, ValueError):
            print(f"::warning::Skipping row with non-numeric chapter/verse: "
                  f"book={raw_book!r} chapter={row['chapter']!r} "
                  f"verse={row['verse']!r}")
            continue
        # Only the row index and verse number are kept here — no audio
        # bytes at all yet, so this whole pass stays cheap regardless
        # of dataset size.
        groups[(slug, chapter_number)].append((row_index, verse_number))

    if unmapped_books:
        print(f"::warning::These book names from the dataset were not "
              f"recognized by book_list.py and were SKIPPED entirely: "
              f"{sorted(unmapped_books)}. If any of these are real books "
              f"(not e.g. a stray testament/section label), add an alias "
              f"in book_list.py's _ALIASES and re-run.")

    print(f"Grouped into {len(groups)} (book, chapter) combinations "
          f"across {len({slug for slug, _ in groups})} books.")
    del metadata_only  # done with this view; free it before pass 2

    work_dir = Path(f"/tmp/afribible_{args.lang_code}")
    work_dir.mkdir(parents=True, exist_ok=True)

    print("Pass 2/2: fetching audio and uploading, one chapter at a time...")

    # Process one BOOK at a time (not one release-per-run for everything)
    # so a failure partway through still leaves earlier books' releases
    # correctly published — same "idempotent, resumable" design as
    # package_english.py.
    books_present = sorted({slug for slug, _ in groups.keys()},
                            key=lambda s: next(n for n, sl, _ in BOOKS if sl == s))

    for slug in books_present:
        book_number = next(n for n, sl, _ in BOOKS if sl == slug)
        tag = release_tag(args.lang_code, book_number, slug)
        existing_assets = ensure_release(
            tag, f"{args.config_name} — {slug} (audio Bible)")

        chapters_for_book = sorted(
            {ch for (sl, ch) in groups if sl == slug}
        )
        for chapter_number in chapters_for_book:
            asset_name = chapter_asset_name(args.lang_code, slug, chapter_number)

            # Real fix, see ensure_release's doc comment — skip work
            # entirely for a chapter that's already on the release from
            # an earlier (possibly rate-limited/crashed) run, rather
            # than re-fetching its audio and re-uploading it.
            if asset_name in existing_assets:
                print(f"Skipping {asset_name} — already uploaded")
                continue

            entries = sorted(groups[(slug, chapter_number)], key=lambda e: e[1])
            row_indices = [i for i, _ in entries]
            verse_numbers = [v for _, v in entries]
            chapter_zip_path = work_dir / asset_name

            # Only THIS chapter's rows (audio included) are fetched here
            # — `select()` is a targeted, efficient lookup against the
            # Arrow-backed dataset, not a full-dataset load.
            chapter_rows = dataset.select(row_indices)

            with zipfile.ZipFile(chapter_zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
                for row, verse_number in zip(chapter_rows, verse_numbers):
                    # `Audio(decode=False)` (cast above) gives raw bytes
                    # directly — written out as-is, no re-encoding, so
                    # original quality/format (confirmed WAV) is
                    # preserved exactly.
                    raw_bytes = row["audio"]["bytes"]
                    verse_filename = f"{args.lang_code}_{slug}_{chapter_number}_{verse_number}.wav"
                    zf.writestr(verse_filename, raw_bytes)

            del chapter_rows  # release this chapter's audio before the next

            upload_asset(tag, chapter_zip_path)
            print(f"Uploaded {asset_name} ({len(entries)} verses)")
            chapter_zip_path.unlink()  # free disk space immediately

    print(f"Done: {args.config_name} ({args.lang_code}), "
          f"{len(books_present)} books, {len(groups)} chapters total.")


if __name__ == "__main__":
    main()
