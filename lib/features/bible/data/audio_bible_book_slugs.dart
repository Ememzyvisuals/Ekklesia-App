/// Canonical book-number -> slug mapping for downloading audio Bible
/// chapters, matching `audio_bible/scripts/book_list.py`'s `BOOKS` list
/// EXACTLY — these slugs are what's actually published as GitHub
/// Release tags/asset names by that pipeline, so this can't be derived
/// from [CanonicalBook.englishName] (bible_books.dart) the easy way:
/// this app's book 22 is named "Song of Solomon", but the published
/// audio slug is "songofsongs" (matching the underlying source data's
/// own file naming) — a naive lowercase-and-strip-spaces transform
/// would silently point at a release that doesn't exist. Hardcoded
/// verbatim from the Python source instead of derived, so there's
/// nothing to accidentally get out of sync via a transform bug.
///
/// If audio_bible/scripts/book_list.py's BOOKS list ever changes, this
/// map must be updated to match — there is no automated check that
/// keeps these two lists in sync across the Python/Dart boundary.
const Map<int, String> kAudioBibleBookSlugs = {
  1: 'genesis',
  2: 'exodus',
  3: 'leviticus',
  4: 'numbers',
  5: 'deuteronomy',
  6: 'joshua',
  7: 'judges',
  8: 'ruth',
  9: '1samuel',
  10: '2samuel',
  11: '1kings',
  12: '2kings',
  13: '1chronicles',
  14: '2chronicles',
  15: 'ezra',
  16: 'nehemiah',
  17: 'esther',
  18: 'job',
  19: 'psalms',
  20: 'proverbs',
  21: 'ecclesiastes',
  22: 'songofsongs',
  23: 'isaiah',
  24: 'jeremiah',
  25: 'lamentations',
  26: 'ezekiel',
  27: 'daniel',
  28: 'hosea',
  29: 'joel',
  30: 'amos',
  31: 'obadiah',
  32: 'jonah',
  33: 'micah',
  34: 'nahum',
  35: 'habakkuk',
  36: 'zephaniah',
  37: 'haggai',
  38: 'zechariah',
  39: 'malachi',
  40: 'matthew',
  41: 'mark',
  42: 'luke',
  43: 'john',
  44: 'acts',
  45: 'romans',
  46: '1corinthians',
  47: '2corinthians',
  48: 'galatians',
  49: 'ephesians',
  50: 'philippians',
  51: 'colossians',
  52: '1thessalonians',
  53: '2thessalonians',
  54: '1timothy',
  55: '2timothy',
  56: 'titus',
  57: 'philemon',
  58: 'hebrews',
  59: 'james',
  60: '1peter',
  61: '2peter',
  62: '1john',
  63: '2john',
  64: '3john',
  65: 'jude',
  66: 'revelation',
};

/// Which app language codes ('en'/'yo'/'ha'/'ig'/'pcm' — see
/// AppConfig/app_settings_service.dart) have real published audio.
/// Matches exactly what audio_bible/README.md documents as actually
/// packaged: English (KJV), Yoruba, Igbo, and Hausa. Pidgin has no open
/// audio source and was never packaged — checked here so the app can
/// hide/disable audio controls for it rather than attempting a download
/// that will always 404.
const Set<String> kAudioBibleAvailableLanguages = {'en', 'yo', 'ig', 'ha'};

/// GitHub release tag for a given language + book — e.g.
/// 'en-01-genesis', 'yo-19-psalms'. Must match
/// audio_bible/scripts/book_list.py's `release_tag()` exactly.
String audioBibleReleaseTag(String langCode, int bookPosition) {
  final slug = kAudioBibleBookSlugs[bookPosition];
  if (slug == null) {
    throw ArgumentError('No audio-bible slug for book position $bookPosition');
  }
  return '$langCode-${bookPosition.toString().padLeft(2, '0')}-$slug';
}

/// GitHub release asset filename for a given chapter — e.g.
/// 'en_genesis_1.zip'. Must match
/// audio_bible/scripts/book_list.py's `chapter_asset_name()` exactly.
String audioBibleChapterAssetName(
    String langCode, int bookPosition, int chapterNumber) {
  final slug = kAudioBibleBookSlugs[bookPosition];
  if (slug == null) {
    throw ArgumentError('No audio-bible slug for book position $bookPosition');
  }
  return '${langCode}_${slug}_$chapterNumber.zip';
}

/// Full download URL for a chapter's audio zip, hosted as a GitHub
/// Release asset on this app's own repo.
String audioBibleDownloadUrl(
    String langCode, int bookPosition, int chapterNumber) {
  final tag = audioBibleReleaseTag(langCode, bookPosition);
  final asset = audioBibleChapterAssetName(langCode, bookPosition, chapterNumber);
  return 'https://github.com/Ememzyvisuals/Ekklesia-App/releases/download/$tag/$asset';
}
