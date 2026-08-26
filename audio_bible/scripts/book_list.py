"""Canonical 66-book King James ordering and naming.

This list is the single source of truth for book numbering and slugs
used across both the English (eliranwong/MP3_KingJamesVersion_american)
and African-language (AfriSpeech/open-bible-speech-african) packaging
pipelines. Keeping one shared list is what lets the app request
"book 19 chapter 23" and get a consistently-named asset regardless of
which language/source it came from.

The (number, slug, eliranwong_zip_stem) tuples were read directly off
the real eliranwong/MP3_KingJamesVersion_american repository file
listing (verified by fetching the repo directly, not guessed), so
`eliranwong_zip_stem` exactly matches that repo's actual zip filenames
zero-padded book number + this stem + ".zip".
"""

# (book_number, slug, eliranwong_zip_stem)
# slug is lowercase, underscore-free, used for release tags/asset names.
# eliranwong_zip_stem is the exact stem GitHub uses for that repo's zips
# (e.g. "Genesis" -> "01_Genesis.zip").
BOOKS = [
    (1, "genesis", "Genesis"),
    (2, "exodus", "Exodus"),
    (3, "leviticus", "Leviticus"),
    (4, "numbers", "Numbers"),
    (5, "deuteronomy", "Deuteronomy"),
    (6, "joshua", "Joshua"),
    (7, "judges", "Judges"),
    (8, "ruth", "Ruth"),
    (9, "1samuel", "1Samuel"),
    (10, "2samuel", "2Samuel"),
    (11, "1kings", "1Kings"),
    (12, "2kings", "2Kings"),
    (13, "1chronicles", "1Chronicles"),
    (14, "2chronicles", "2Chronicles"),
    (15, "ezra", "Ezra"),
    (16, "nehemiah", "Nehemiah"),
    (17, "esther", "Esther"),
    (18, "job", "Job"),
    (19, "psalms", "Psalms"),
    (20, "proverbs", "Proverbs"),
    (21, "ecclesiastes", "Ecclesiastes"),
    (22, "songofsongs", "Song_of_Songs"),
    (23, "isaiah", "Isaiah"),
    (24, "jeremiah", "Jeremiah"),
    (25, "lamentations", "Lamentations"),
    (26, "ezekiel", "Ezekiel"),
    (27, "daniel", "Daniel"),
    (28, "hosea", "Hosea"),
    (29, "joel", "Joel"),
    (30, "amos", "Amos"),
    (31, "obadiah", "Obadiah"),
    (32, "jonah", "Jonah"),
    (33, "micah", "Micah"),
    (34, "nahum", "Nahum"),
    (35, "habakkuk", "Habakkuk"),
    (36, "zephaniah", "Zephaniah"),
    (37, "haggai", "Haggai"),
    (38, "zechariah", "Zechariah"),
    (39, "malachi", "Malachi"),
    (40, "matthew", "Matthew"),
    (41, "mark", "Mark"),
    (42, "luke", "Luke"),
    (43, "john", "John"),
    (44, "acts", "Acts_of_Apostles"),
    (45, "romans", "Romans"),
    (46, "1corinthians", "1Corinthians"),
    (47, "2corinthians", "2Corinthians"),
    (48, "galatians", "Galatians"),
    (49, "ephesians", "Ephesians"),
    (50, "philippians", "Philippians"),
    (51, "colossians", "Colossians"),
    (52, "1thessalonians", "1Thessalonians"),
    (53, "2thessalonians", "2Thessalonians"),
    (54, "1timothy", "1Timothy"),
    (55, "2timothy", "2Timothy"),
    (56, "titus", "Titus"),
    (57, "philemon", "Philemon"),
    (58, "hebrews", "Hebrews"),
    (59, "james", "James"),
    (60, "1peter", "1Peter"),
    (61, "2peter", "2Peter"),
    (62, "1john", "1John"),
    (63, "2john", "2John"),
    (64, "3john", "3John"),
    (65, "jude", "Jude"),
    (66, "revelation", "Revelation"),
]

_SLUG_BY_NUM = {num: slug for num, slug, _ in BOOKS}
_NUM_BY_SLUG = {slug: num for num, slug, _ in BOOKS}


def _normalize(name: str) -> str:
    """Lowercases and strips spaces/underscores for loose comparison."""
    return name.lower().replace(" ", "").replace("_", "")


# Explicit aliases for source book names that don't reduce to the same
# normalized string as our canonical slug even after stripping spaces/
# underscores (e.g. AfriSpeech's plain "Acts" vs our "acts" slug is fine
# via normalization alone, but book names that use ordinal words or
# different abbreviations would not be — kept here so a future new
# source's naming quirk has one place to add an override rather than
# needing to edit BOOKS itself).
_ALIASES = {
    "actsoftheapostles": "acts",
    "songofsolomon": "songofsongs",
    "canticles": "songofsongs",
}

_NORMALIZED_TO_SLUG = {_normalize(slug): slug for slug in _NUM_BY_SLUG}
_NORMALIZED_TO_SLUG.update(_ALIASES)


def slug_for_book_name(raw_name: str) -> str | None:
    """Maps a book name string from any source (e.g. AfriSpeech's "2
    Kings", "Song of Songs") to our canonical slug (e.g. "2kings",
    "songofsongs"). Returns None if the name isn't recognized — callers
    should treat that as "skip this row rather than guess," since a
    silent wrong mapping would misfile audio under the wrong book.
    """
    normalized = _normalize(raw_name)
    return _NORMALIZED_TO_SLUG.get(normalized)


def book_number_for_slug(slug: str) -> int:
    return _NUM_BY_SLUG[slug]


def eliranwong_zip_url(book_number: int, zip_stem: str) -> str:
    return (
        "https://github.com/eliranwong/MP3_KingJamesVersion_american/"
        f"raw/main/{book_number:02d}_{zip_stem}.zip"
    )


def release_tag(lang_code: str, book_number: int, slug: str) -> str:
    """e.g. 'en-01-genesis', 'yo-19-psalms'."""
    return f"{lang_code}-{book_number:02d}-{slug}"


def chapter_asset_name(lang_code: str, slug: str, chapter_number: int) -> str:
    """e.g. 'en_genesis_1.zip', 'yo_psalms_23.zip'."""
    return f"{lang_code}_{slug}_{chapter_number}.zip"
