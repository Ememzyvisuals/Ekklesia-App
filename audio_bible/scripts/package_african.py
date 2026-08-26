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
import os
import subprocess
import sys
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


def ensure_release(tag: str, title: str) -> None:
    result = subprocess.run(
        ["gh", "release", "view", tag], capture_output=True, text=True
    )
    if result.returncode != 0:
        gh("release", "create", tag, "--title", title, "--notes",
           f"Chapter-by-chapter audio Bible assets ({title}).")
        print(f"Created release {tag}")
    else:
        print(f"Release {tag} already exists — reusing it")


def upload_asset(tag: str, asset_path: Path) -> None:
    gh("release", "upload", tag, str(asset_path), "--clobber")


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

    # Group rows by (book_slug, chapter_number) so each group becomes
    # one chapter zip, mirroring package_english.py's structure exactly.
    groups: dict[tuple[str, int], list[dict]] = defaultdict(list)
    unmapped_books: set[str] = set()

    for row in dataset:
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
        groups[(slug, chapter_number)].append(
            {"verse": verse_number, "audio": row["audio"]}
        )

    if unmapped_books:
        print(f"::warning::These book names from the dataset were not "
              f"recognized by book_list.py and were SKIPPED entirely: "
              f"{sorted(unmapped_books)}. If any of these are real books "
              f"(not e.g. a stray testament/section label), add an alias "
              f"in book_list.py's _ALIASES and re-run.")

    print(f"Grouped into {len(groups)} (book, chapter) combinations "
          f"across {len({slug for slug, _ in groups})} books.")

    work_dir = Path(f"/tmp/afribible_{args.lang_code}")
    work_dir.mkdir(parents=True, exist_ok=True)

    # Process one BOOK at a time (not one release-per-run for everything)
    # so a failure partway through still leaves earlier books' releases
    # correctly published — same "idempotent, resumable" design as
    # package_english.py.
    books_present = sorted({slug for slug, _ in groups.keys()},
                            key=lambda s: next(n for n, sl, _ in BOOKS if sl == s))

    for slug in books_present:
        book_number = next(n for n, sl, _ in BOOKS if sl == slug)
        tag = release_tag(args.lang_code, book_number, slug)
        ensure_release(tag, f"{args.config_name} — {slug} (audio Bible)")

        chapters_for_book = sorted(
            {ch for (sl, ch) in groups if sl == slug}
        )
        for chapter_number in chapters_for_book:
            verses = sorted(groups[(slug, chapter_number)], key=lambda v: v["verse"])
            asset_name = chapter_asset_name(args.lang_code, slug, chapter_number)
            chapter_zip_path = work_dir / asset_name

            with zipfile.ZipFile(chapter_zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
                for v in verses:
                    audio = v["audio"]
                    # `Audio(decode=False)` (see the dataset loading
                    # call below via `.cast_column`) gives raw bytes
                    # directly — written out as-is, no re-encoding, so
                    # original quality/format (confirmed WAV) is
                    # preserved exactly.
                    raw_bytes = audio["bytes"]
                    verse_filename = f"{args.lang_code}_{slug}_{chapter_number}_{v['verse']}.wav"
                    zf.writestr(verse_filename, raw_bytes)

            upload_asset(tag, chapter_zip_path)
            print(f"Uploaded {asset_name} ({len(verses)} verses)")
            chapter_zip_path.unlink()  # free disk space immediately

    print(f"Done: {args.config_name} ({args.lang_code}), "
          f"{len(books_present)} books, {len(groups)} chapters total.")


if __name__ == "__main__":
    main()
