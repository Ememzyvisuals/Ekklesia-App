import 'package:flutter_test/flutter_test.dart';

import 'package:ekklesia/features/bible/data/bible_repository.dart';

void main() {
  group('parseBibleReference', () {
    test('parses "Book Chapter:Verse"', () {
      final ref = parseBibleReference('John 3:16');
      expect(ref.book.code, 'JHN');
      expect(ref.chapter, 3);
      expect(ref.startVerse, 16);
      expect(ref.endVerse, 16);
    });

    test('parses "Book Chapter:StartVerse-EndVerse" as a range', () {
      final ref = parseBibleReference('Romans 8:28-30');
      expect(ref.book.code, 'ROM');
      expect(ref.chapter, 8);
      expect(ref.startVerse, 28);
      expect(ref.endVerse, 30);
    });

    test('parses "Book Chapter" with no verse (whole chapter)', () {
      final ref = parseBibleReference('Psalms 23');
      expect(ref.book.code, 'PSA');
      expect(ref.chapter, 23);
      expect(ref.startVerse, isNull);
      expect(ref.endVerse, isNull);
    });

    test('parses numbered books ("1 Samuel 17:45")', () {
      final ref = parseBibleReference('1 Samuel 17:45');
      expect(ref.book.code, '1SA');
      expect(ref.chapter, 17);
      expect(ref.startVerse, 45);
    });

    test('tolerates extra whitespace', () {
      final ref = parseBibleReference('  John   3:16  ');
      expect(ref.book.code, 'JHN');
      expect(ref.chapter, 3);
    });

    test('throws BibleReferenceException for an unparseable string', () {
      expect(() => parseBibleReference('not a reference'),
          throwsA(isA<BibleReferenceException>()));
      expect(() => parseBibleReference(''),
          throwsA(isA<BibleReferenceException>()));
    });

    test('throws BibleReferenceException for an unknown book name', () {
      expect(() => parseBibleReference('Frodo 3:16'),
          throwsA(isA<BibleReferenceException>()));
    });
  });
}
