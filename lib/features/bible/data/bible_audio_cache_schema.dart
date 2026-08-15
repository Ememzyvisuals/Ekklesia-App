import 'package:isar_community/isar.dart';

part 'bible_audio_cache_schema.g.dart';

/// One row per (language, book, chapter) that's had audio generated and
/// saved locally. [contentHash] is a hash of the chapter's concatenated
/// verse text at generation time — if a later Bible re-import changes that
/// text (e.g. an anomaly gets fixed upstream), the hash won't match and
/// BibleAudioCache falls back to regenerating instead of serving stale
/// audio for different text.
@collection
class BibleAudioCacheEntity {
  Id id = Isar.autoIncrement;

  @Index(composite: [CompositeIndex('bookCode'), CompositeIndex('chapter')])
  late String language;

  late String bookCode;
  late int chapter;
  late String contentHash;

  /// Ordered local file paths (one per TTS chunk) — played back-to-back by
  /// AudioService.playQueue in this order.
  late List<String> chunkPaths;

  /// Name of the AudioSource enum value that generated this audio
  /// (stored as a string since Isar enums need explicit mapping and this
  /// is simpler for a single field — see bibleAudioSource getter).
  late String audioSourceName;

  late DateTime generatedAt;
  late int totalBytes;
}
