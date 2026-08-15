import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/services/audio_service.dart';
import '../../../core/services/tts_service.dart';
import 'bible_audio_cache_schema.dart';

/// Caches generated chapter audio to local disk so tapping "Listen" on the
/// same chapter again plays instantly from disk instead of re-generating
/// through the TTS Space (slow, and burns free-tier quota for no reason).
///
/// Keyed by (language, book, chapter) + a hash of the chapter's verse text,
/// so if the underlying Bible data is ever corrected (re-import with fixed
/// text), the stale cached audio is detected and regenerated rather than
/// silently played forever.
class BibleAudioCache {
  BibleAudioCache(this.isar);
  final Isar isar;

  static String hashFor(String text) =>
      sha256.convert(utf8.encode(text)).toString();

  Future<Directory> _cacheDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/bible_audio');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Returns the cached manifest only if it exists, matches [contentHash],
  /// and every chunk file is still actually present on disk (defensive —
  /// OS storage pressure or a manual app-data clear could remove files
  /// without this app knowing).
  Future<BibleAudioCacheEntity?> get(
    String language,
    String bookCode,
    int chapter,
    String contentHash,
  ) async {
    final entry = await isar.bibleAudioCacheEntitys
        .filter()
        .languageEqualTo(language)
        .bookCodeEqualTo(bookCode)
        .chapterEqualTo(chapter)
        .findFirst();
    if (entry == null || entry.contentHash != contentHash) return null;
    for (final p in entry.chunkPaths) {
      if (!await File(p).exists()) return null;
    }
    return entry;
  }

  AudioSource sourceFor(String name) {
    return AudioSource.values.firstWhere((s) => s.name == name,
        orElse: () => AudioSource.onDeviceTts);
  }

  /// Downloads each chunk's remote TTS audio to a local file and records
  /// the manifest, replacing any previous cached audio for this chapter.
  /// Called after playback has already started from the remote URLs (see
  /// bible_screen.dart) so downloading never delays the user hearing
  /// anything — this only affects the *next* time they open this chapter.
  Future<BibleAudioCacheEntity> save({
    required String language,
    required String bookCode,
    required int chapter,
    required String contentHash,
    required List<TtsResult> chunks,
  }) async {
    if (chunks.isEmpty) {
      throw Exception(
          'Cannot cache zero audio chunks for $bookCode $chapter ($language).');
    }
    final dir = await _cacheDir();
    final paths = <String>[];
    var totalBytes = 0;

    for (var i = 0; i < chunks.length; i++) {
      final response = await http.get(Uri.parse(chunks[i].audioUrl));
      if (response.statusCode != 200) {
        throw Exception(
            'Failed to download TTS audio chunk $i for caching (${response.statusCode}).');
      }
      final file =
          File('${dir.path}/${language}_${bookCode}_${chapter}_$i.mp3');
      await file.writeAsBytes(response.bodyBytes);
      paths.add(file.path);
      totalBytes += response.bodyBytes.length;
    }

    final existing = await isar.bibleAudioCacheEntitys
        .filter()
        .languageEqualTo(language)
        .bookCodeEqualTo(bookCode)
        .chapterEqualTo(chapter)
        .findFirst();

    // Clean up orphaned files from a previous cache of this same chapter
    // (e.g. if chunk count changed between generations).
    if (existing != null) {
      for (final oldPath in existing.chunkPaths) {
        if (!paths.contains(oldPath)) {
          final f = File(oldPath);
          if (await f.exists()) await f.delete();
        }
      }
    }

    final entity = BibleAudioCacheEntity()
      ..language = language
      ..bookCode = bookCode
      ..chapter = chapter
      ..contentHash = contentHash
      ..chunkPaths = paths
      ..audioSourceName = chunks.first.source.name
      ..generatedAt = DateTime.now()
      ..totalBytes = totalBytes;

    await isar.writeTxn(() async {
      if (existing != null) {
        await isar.bibleAudioCacheEntitys.delete(existing.id);
      }
      await isar.bibleAudioCacheEntitys.put(entity);
    });

    return entity;
  }

  /// Total bytes of cached Bible audio on disk — for a future "Storage
  /// Statistics" UI (spec's Download System section asks for this).
  Future<int> totalCachedBytes() async {
    final all = await isar.bibleAudioCacheEntitys.where().findAll();
    return all.fold<int>(0, (sum, e) => sum + e.totalBytes);
  }

  /// Reconciles disk and Isar: deletes any file in the cache directory not
  /// referenced by a current [BibleAudioCacheEntity] row (e.g. left behind
  /// by an interrupted [save] call), and removes any row whose files no
  /// longer exist on disk (e.g. app storage was cleared out from under
  /// this app). Called by CleanupWorker's periodic housekeeping pass
  /// rather than as a separate standalone worker — the spec lists a
  /// dedicated `BibleCleanupWorker`, but this is a few lines of real work
  /// bolted onto the cleanup pass that already exists and already runs on
  /// a schedule, not a reason to stand up a second timer/worker class
  /// that would just call this same method.
  Future<void> pruneOrphaned() async {
    final dir = await _cacheDir();
    final allEntries = await isar.bibleAudioCacheEntitys.where().findAll();
    final referencedPaths = <String>{
      for (final e in allEntries) ...e.chunkPaths
    };

    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!referencedPaths.contains(entity.path)) {
          try {
            await entity.delete();
          } catch (_) {
            // best-effort — skip files that are locked/in-use this pass
          }
        }
      }
    }

    final staleIds = <int>[];
    for (final e in allEntries) {
      var anyMissing = false;
      for (final p in e.chunkPaths) {
        if (!await File(p).exists()) {
          anyMissing = true;
          break;
        }
      }
      if (anyMissing) staleIds.add(e.id);
    }
    if (staleIds.isNotEmpty) {
      await isar
          .writeTxn(() => isar.bibleAudioCacheEntitys.deleteAll(staleIds));
    }
  }

  /// Deletes every cached chapter's audio files and manifest rows.
  Future<void> clearAll() async {
    final all = await isar.bibleAudioCacheEntitys.where().findAll();
    for (final e in all) {
      for (final p in e.chunkPaths) {
        final f = File(p);
        if (await f.exists()) await f.delete();
      }
    }
    await isar.writeTxn(() => isar.bibleAudioCacheEntitys.clear());
  }
}
