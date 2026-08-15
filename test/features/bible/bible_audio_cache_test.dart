import 'package:flutter_test/flutter_test.dart';

import 'package:ekklesia/features/bible/data/bible_audio_cache.dart';

void main() {
  group('BibleAudioCache.hashFor', () {
    test('is deterministic for identical text', () {
      const text = 'In the beginning God created the heavens and the earth.';
      expect(BibleAudioCache.hashFor(text), BibleAudioCache.hashFor(text));
    });

    test('differs for different text', () {
      expect(
        BibleAudioCache.hashFor('Genesis 1:1 text'),
        isNot(BibleAudioCache.hashFor('Genesis 1:2 text')),
      );
    });

    test('is sensitive to whitespace/casing (exact-match cache key, not fuzzy)',
        () {
      expect(
        BibleAudioCache.hashFor('Hello World'),
        isNot(BibleAudioCache.hashFor('hello world')),
      );
    });

    test('produces a 64-character lowercase hex string (sha256)', () {
      final hash = BibleAudioCache.hashFor('anything');
      expect(hash.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(hash), isTrue);
    });
  });
}
