import 'package:flutter_test/flutter_test.dart';

import 'package:ekklesia/features/bible/domain/bible_books.dart';

void main() {
  group('kCanonicalBooks', () {
    test('has exactly 66 books', () {
      expect(kCanonicalBooks.length, 66);
    });

    test('positions are 1..66 with no gaps or duplicates', () {
      final positions = kCanonicalBooks.map((b) => b.position).toList()..sort();
      expect(positions, List.generate(66, (i) => i + 1));
    });

    test('codes are unique', () {
      final codes = kCanonicalBooks.map((b) => b.code).toSet();
      expect(codes.length, 66);
    });

    test('Old Testament is exactly the first 39 by position (Genesis..Malachi)',
        () {
      final ot = kCanonicalBooks.where((b) => b.testament == 'OT').toList();
      expect(ot.length, 39);
      expect(ot.map((b) => b.position).reduce((a, b) => a > b ? a : b), 39);
      expect(kCanonicalBooksByCode['MAL']!.testament, 'OT');
      expect(kCanonicalBooksByCode['MAT']!.testament, 'NT');
    });

    test('New Testament is exactly the remaining 27 (Matthew..Revelation)', () {
      final nt = kCanonicalBooks.where((b) => b.testament == 'NT').toList();
      expect(nt.length, 27);
    });

    test('kCanonicalBooksByCode is a complete, consistent index', () {
      for (final book in kCanonicalBooks) {
        expect(kCanonicalBooksByCode[book.code], same(book));
      }
    });
  });

  group('findCanonicalBookByName', () {
    test('matches exact English names', () {
      expect(findCanonicalBookByName('Genesis')?.code, 'GEN');
      expect(findCanonicalBookByName('Revelation')?.code, 'REV');
    });

    test('is case-insensitive', () {
      expect(findCanonicalBookByName('genesis')?.code, 'GEN');
      expect(findCanonicalBookByName('JOHN')?.code, 'JHN');
    });

    test('handles numbered books with a space ("1 Samuel")', () {
      expect(findCanonicalBookByName('1 Samuel')?.code, '1SA');
      expect(findCanonicalBookByName('2 Corinthians')?.code, '2CO');
      expect(findCanonicalBookByName('3 John')?.code, '3JN');
    });

    test('handles numbered books without a space ("1Samuel")', () {
      expect(findCanonicalBookByName('1Samuel')?.code, '1SA');
    });

    test('handles ordinal-word prefixes ("First Samuel", "Second Kings")', () {
      expect(findCanonicalBookByName('First Samuel')?.code, '1SA');
      expect(findCanonicalBookByName('Second Kings')?.code, '2KI');
    });

    test('handles multi-word names ("Song of Solomon")', () {
      expect(findCanonicalBookByName('Song of Solomon')?.code, 'SNG');
    });

    test('returns null for unknown input rather than throwing', () {
      expect(findCanonicalBookByName('Not A Real Book'), isNull);
      expect(findCanonicalBookByName(''), isNull);
    });
  });
}
