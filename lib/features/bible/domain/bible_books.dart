/// Canonical Protestant 66-book registry (standard USFM-style 3-letter
/// codes). This is structural/bibliographic metadata — book order, English
/// names, testament — not scripture text, so it's safe to hardcode.
///
/// Every imported language dataset (assets/bible/*.json) uses these same
/// [code] values to key its books, so UI can look up "Genesis" -> 'GEN' ->
/// the correct book in whichever language is active.
class CanonicalBook {
  const CanonicalBook({
    required this.code,
    required this.englishName,
    required this.testament,
    required this.position,
  });

  final String code;
  final String englishName;
  final String testament; // 'OT' or 'NT'
  final int position; // 1..66, canonical Protestant order
}

const List<CanonicalBook> kCanonicalBooks = [
  CanonicalBook(
      code: 'GEN', englishName: 'Genesis', testament: 'OT', position: 1),
  CanonicalBook(
      code: 'EXO', englishName: 'Exodus', testament: 'OT', position: 2),
  CanonicalBook(
      code: 'LEV', englishName: 'Leviticus', testament: 'OT', position: 3),
  CanonicalBook(
      code: 'NUM', englishName: 'Numbers', testament: 'OT', position: 4),
  CanonicalBook(
      code: 'DEU', englishName: 'Deuteronomy', testament: 'OT', position: 5),
  CanonicalBook(
      code: 'JOS', englishName: 'Joshua', testament: 'OT', position: 6),
  CanonicalBook(
      code: 'JDG', englishName: 'Judges', testament: 'OT', position: 7),
  CanonicalBook(code: 'RUT', englishName: 'Ruth', testament: 'OT', position: 8),
  CanonicalBook(
      code: '1SA', englishName: '1 Samuel', testament: 'OT', position: 9),
  CanonicalBook(
      code: '2SA', englishName: '2 Samuel', testament: 'OT', position: 10),
  CanonicalBook(
      code: '1KI', englishName: '1 Kings', testament: 'OT', position: 11),
  CanonicalBook(
      code: '2KI', englishName: '2 Kings', testament: 'OT', position: 12),
  CanonicalBook(
      code: '1CH', englishName: '1 Chronicles', testament: 'OT', position: 13),
  CanonicalBook(
      code: '2CH', englishName: '2 Chronicles', testament: 'OT', position: 14),
  CanonicalBook(
      code: 'EZR', englishName: 'Ezra', testament: 'OT', position: 15),
  CanonicalBook(
      code: 'NEH', englishName: 'Nehemiah', testament: 'OT', position: 16),
  CanonicalBook(
      code: 'EST', englishName: 'Esther', testament: 'OT', position: 17),
  CanonicalBook(code: 'JOB', englishName: 'Job', testament: 'OT', position: 18),
  CanonicalBook(
      code: 'PSA', englishName: 'Psalms', testament: 'OT', position: 19),
  CanonicalBook(
      code: 'PRO', englishName: 'Proverbs', testament: 'OT', position: 20),
  CanonicalBook(
      code: 'ECC', englishName: 'Ecclesiastes', testament: 'OT', position: 21),
  CanonicalBook(
      code: 'SNG',
      englishName: 'Song of Solomon',
      testament: 'OT',
      position: 22),
  CanonicalBook(
      code: 'ISA', englishName: 'Isaiah', testament: 'OT', position: 23),
  CanonicalBook(
      code: 'JER', englishName: 'Jeremiah', testament: 'OT', position: 24),
  CanonicalBook(
      code: 'LAM', englishName: 'Lamentations', testament: 'OT', position: 25),
  CanonicalBook(
      code: 'EZK', englishName: 'Ezekiel', testament: 'OT', position: 26),
  CanonicalBook(
      code: 'DAN', englishName: 'Daniel', testament: 'OT', position: 27),
  CanonicalBook(
      code: 'HOS', englishName: 'Hosea', testament: 'OT', position: 28),
  CanonicalBook(
      code: 'JOL', englishName: 'Joel', testament: 'OT', position: 29),
  CanonicalBook(
      code: 'AMO', englishName: 'Amos', testament: 'OT', position: 30),
  CanonicalBook(
      code: 'OBA', englishName: 'Obadiah', testament: 'OT', position: 31),
  CanonicalBook(
      code: 'JON', englishName: 'Jonah', testament: 'OT', position: 32),
  CanonicalBook(
      code: 'MIC', englishName: 'Micah', testament: 'OT', position: 33),
  CanonicalBook(
      code: 'NAM', englishName: 'Nahum', testament: 'OT', position: 34),
  CanonicalBook(
      code: 'HAB', englishName: 'Habakkuk', testament: 'OT', position: 35),
  CanonicalBook(
      code: 'ZEP', englishName: 'Zephaniah', testament: 'OT', position: 36),
  CanonicalBook(
      code: 'HAG', englishName: 'Haggai', testament: 'OT', position: 37),
  CanonicalBook(
      code: 'ZEC', englishName: 'Zechariah', testament: 'OT', position: 38),
  CanonicalBook(
      code: 'MAL', englishName: 'Malachi', testament: 'OT', position: 39),
  CanonicalBook(
      code: 'MAT', englishName: 'Matthew', testament: 'NT', position: 40),
  CanonicalBook(
      code: 'MRK', englishName: 'Mark', testament: 'NT', position: 41),
  CanonicalBook(
      code: 'LUK', englishName: 'Luke', testament: 'NT', position: 42),
  CanonicalBook(
      code: 'JHN', englishName: 'John', testament: 'NT', position: 43),
  CanonicalBook(
      code: 'ACT', englishName: 'Acts', testament: 'NT', position: 44),
  CanonicalBook(
      code: 'ROM', englishName: 'Romans', testament: 'NT', position: 45),
  CanonicalBook(
      code: '1CO', englishName: '1 Corinthians', testament: 'NT', position: 46),
  CanonicalBook(
      code: '2CO', englishName: '2 Corinthians', testament: 'NT', position: 47),
  CanonicalBook(
      code: 'GAL', englishName: 'Galatians', testament: 'NT', position: 48),
  CanonicalBook(
      code: 'EPH', englishName: 'Ephesians', testament: 'NT', position: 49),
  CanonicalBook(
      code: 'PHP', englishName: 'Philippians', testament: 'NT', position: 50),
  CanonicalBook(
      code: 'COL', englishName: 'Colossians', testament: 'NT', position: 51),
  CanonicalBook(
      code: '1TH',
      englishName: '1 Thessalonians',
      testament: 'NT',
      position: 52),
  CanonicalBook(
      code: '2TH',
      englishName: '2 Thessalonians',
      testament: 'NT',
      position: 53),
  CanonicalBook(
      code: '1TI', englishName: '1 Timothy', testament: 'NT', position: 54),
  CanonicalBook(
      code: '2TI', englishName: '2 Timothy', testament: 'NT', position: 55),
  CanonicalBook(
      code: 'TIT', englishName: 'Titus', testament: 'NT', position: 56),
  CanonicalBook(
      code: 'PHM', englishName: 'Philemon', testament: 'NT', position: 57),
  CanonicalBook(
      code: 'HEB', englishName: 'Hebrews', testament: 'NT', position: 58),
  CanonicalBook(
      code: 'JAS', englishName: 'James', testament: 'NT', position: 59),
  CanonicalBook(
      code: '1PE', englishName: '1 Peter', testament: 'NT', position: 60),
  CanonicalBook(
      code: '2PE', englishName: '2 Peter', testament: 'NT', position: 61),
  CanonicalBook(
      code: '1JN', englishName: '1 John', testament: 'NT', position: 62),
  CanonicalBook(
      code: '2JN', englishName: '2 John', testament: 'NT', position: 63),
  CanonicalBook(
      code: '3JN', englishName: '3 John', testament: 'NT', position: 64),
  CanonicalBook(
      code: 'JUD', englishName: 'Jude', testament: 'NT', position: 65),
  CanonicalBook(
      code: 'REV', englishName: 'Revelation', testament: 'NT', position: 66),
];

final Map<String, CanonicalBook> kCanonicalBooksByCode = {
  for (final b in kCanonicalBooks) b.code: b,
};

/// Loose matcher for reference parsing: "1 Samuel", "1Samuel", "1st Samuel",
/// "I Samuel" all resolve to '1SA'. Case-insensitive, punctuation-insensitive.
CanonicalBook? findCanonicalBookByName(String input) {
  final normalized = input
      .toLowerCase()
      .replaceAll('.', '')
      .replaceAll(RegExp(r'^(1st|first|i)\s'), '1 ')
      .replaceAll(RegExp(r'^(2nd|second|ii)\s'), '2 ')
      .replaceAll(RegExp(r'^(3rd|third|iii)\s'), '3 ')
      .trim();
  for (final b in kCanonicalBooks) {
    final bn = b.englishName.toLowerCase();
    if (bn == normalized ||
        bn.replaceAll(' ', '') == normalized.replaceAll(' ', '')) {
      return b;
    }
  }
  return null;
}
