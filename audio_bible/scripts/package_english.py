"""Downloads one KJV book's zip (eliranwong/MP3_KingJamesVersion_american),
repackages it into one zip per chapter, and creates/updates a GitHub
Release with those chapter zips as assets.

Usage: python3 package_english.py <book_number>
Requires: GITHUB_TOKEN, RELEASE_REPO ("owner/repo") in the environment.
Requires the `gh` CLI to be authenticated (GITHUB_TOKEN covers this
automatically in GitHub Actions).

Real structure this was written against (verified by actually
downloading and unzipping 01_Genesis.zip, not assumed): each book zip
contains one folder per chapter named "{book_number}_{chapter_number}/"
(no zero-padding), and each folder holds verse files named
"KJV_{book_number}_{chapter_number}_{verse_number}.mp3".
"""
import os
import re
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

from book_list import BOOKS, eliranwong_zip_url, release_tag, chapter_asset_name

LANG_CODE = "en"


def download(url: str, dest: Path) -> None:
    print(f"Downloading {url}")
    urllib.request.urlretrieve(url, dest)


def gh(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True)


def ensure_release(tag: str, title: str) -> None:
    """Creates the release if it doesn't already exist. Idempotent —
    safe to re-run this whole script if a previous run failed partway.
    """
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
    """Uploads (or overwrites) one asset on an existing release. Clobber
    mode makes this safe to re-run if a chapter zip needs to be
    regenerated.
    """
    gh("release", "upload", tag, str(asset_path), "--clobber")


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: package_english.py <book_number>", file=sys.stderr)
        sys.exit(1)
    book_number = int(sys.argv[1])

    book = next((b for b in BOOKS if b[0] == book_number), None)
    if book is None:
        print(f"::error::No book #{book_number} in BOOKS", file=sys.stderr)
        sys.exit(1)
    _, slug, zip_stem = book

    work_dir = Path(f"/tmp/kjv_{slug}")
    work_dir.mkdir(parents=True, exist_ok=True)
    zip_path = work_dir / "book.zip"
    extract_dir = work_dir / "extracted"
    chapters_dir = work_dir / "chapters"
    extract_dir.mkdir(exist_ok=True)
    chapters_dir.mkdir(exist_ok=True)

    download(eliranwong_zip_url(book_number, zip_stem), zip_path)

    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(extract_dir)

    # Folders look like "{book_number}_{chapter_number}" — no zero
    # padding, confirmed against the real Genesis zip (folders "1_1",
    # "1_9", "1_41", etc.).
    chapter_folder_re = re.compile(rf"^{book_number}_(\d+)$")
    chapter_folders = sorted(
        (p for p in extract_dir.iterdir() if p.is_dir() and chapter_folder_re.match(p.name)),
        key=lambda p: int(chapter_folder_re.match(p.name).group(1)),
    )

    if not chapter_folders:
        print(f"::error::No chapter folders found for book {book_number} "
              f"({slug}) — extraction or naming assumption may be wrong.",
              file=sys.stderr)
        sys.exit(1)

    tag = release_tag(LANG_CODE, book_number, slug)
    ensure_release(tag, f"KJV English — {zip_stem.replace('_', ' ')}")

    for folder in chapter_folders:
        chapter_number = int(chapter_folder_re.match(folder.name).group(1))
        asset_name = chapter_asset_name(LANG_CODE, slug, chapter_number)
        chapter_zip_path = chapters_dir / asset_name

        mp3_files = sorted(folder.glob("*.mp3"))
        if not mp3_files:
            print(f"::warning::Chapter {chapter_number} of {slug} has no "
                  f"mp3 files — skipping.")
            continue

        with zipfile.ZipFile(chapter_zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            for mp3 in mp3_files:
                # Store just the verse filename inside the chapter zip —
                # flat structure, no book/chapter folder nesting, so the
                # app can extract straight into one directory per
                # chapter without recreating this pipeline's own folder
                # layout.
                zf.write(mp3, arcname=mp3.name)

        upload_asset(tag, chapter_zip_path)
        print(f"Uploaded {asset_name} ({len(mp3_files)} verses)")

    # Free disk space before the next matrix job step (if any) — book
    # zips can be tens of MB and the runner's disk isn't unlimited.
    shutil.rmtree(work_dir, ignore_errors=True)
    print(f"Done: book {book_number} ({slug}), {len(chapter_folders)} chapters")


if __name__ == "__main__":
    main()
