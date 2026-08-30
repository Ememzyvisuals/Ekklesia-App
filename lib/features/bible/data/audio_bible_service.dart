import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'audio_bible_book_slugs.dart';

/// Download progress for one chapter — `received`/`total` in bytes.
/// `total` is null if the server didn't report a Content-Length (rare
/// for GitHub Release assets, but not guaranteed), in which case the UI
/// should show an indeterminate spinner rather than a percentage.
class AudioBibleDownloadProgress {
  AudioBibleDownloadProgress({required this.received, required this.total});
  final int received;
  final int? total;
}

/// Thrown when a chapter's audio isn't published for the requested
/// language — e.g. Pidgin (no source was ever found; see
/// audio_bible/README.md) or a language/book/chapter combination that
/// genuinely doesn't exist as a release.
class AudioBibleUnavailableException implements Exception {
  const AudioBibleUnavailableException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads, caches, and plays pre-recorded audio Bible chapters —
/// replaces TTS entirely (see pubspec.yaml's removal notes). Audio is
/// downloaded once per chapter (from this repo's own GitHub Releases,
/// see audio_bible/ at the repo root for how it got there) and kept on
/// disk indefinitely, unlike TTS output which was regenerated or cached
/// per exact chapter-text hash — a chapter's audio never changes, so
/// there's no cache-invalidation question to answer here.
class AudioBibleService {
  AudioBibleService._internal();
  static final AudioBibleService instance = AudioBibleService._internal();

  final AudioPlayer _player = AudioPlayer();
  AudioPlayer get player => _player;

  /// Bumped on every [playChapter]/[stop] call so an in-flight sequential
  /// playback loop can tell it's been superseded and stop advancing to
  /// its next verse instead of talking over new audio — same pattern
  /// the old (now-removed) AudioService.playQueue used.
  int _playToken = 0;

  final _progressController =
      StreamController<AudioBibleDownloadProgress?>.broadcast();
  Stream<AudioBibleDownloadProgress?> get downloadProgressStream =>
      _progressController.stream;

  Future<Directory> _chapterDir(
      String langCode, int bookPosition, int chapterNumber) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final slug = kAudioBibleBookSlugs[bookPosition];
    return Directory(p.join(docsDir.path, 'audio_bible', langCode,
        '${bookPosition.toString().padLeft(2, '0')}_$slug', 'ch$chapterNumber'));
  }

  /// True if this chapter's audio is already downloaded and extracted.
  Future<bool> isDownloaded(
      String langCode, int bookPosition, int chapterNumber) async {
    final dir = await _chapterDir(langCode, bookPosition, chapterNumber);
    if (!await dir.exists()) return false;
    // Non-empty check, not just exists() — an interrupted extraction
    // could in principle leave an empty directory behind (though
    // ensureDownloaded below cleans up on failure; this is a cheap
    // extra guard against any other way an empty dir could appear).
    await for (final _ in dir.list()) {
      return true;
    }
    return false;
  }

  /// Downloads and extracts a chapter's audio if not already present.
  /// No-ops immediately if [isDownloaded] is already true. Progress is
  /// reported via [downloadProgressStream] during the download (not
  /// during extraction, which is fast — verse zips are small).
  Future<void> ensureDownloaded(
      String langCode, int bookPosition, int chapterNumber) async {
    if (!kAudioBibleAvailableLanguages.contains(langCode)) {
      throw AudioBibleUnavailableException(
          'No audio Bible is available for this language yet.');
    }
    if (await isDownloaded(langCode, bookPosition, chapterNumber)) return;

    final url = audioBibleDownloadUrl(langCode, bookPosition, chapterNumber);
    final targetDir = await _chapterDir(langCode, bookPosition, chapterNumber);
    final tempZip = File(p.join(
        (await getTemporaryDirectory()).path,
        'audio_bible_dl_${DateTime.now().microsecondsSinceEpoch}.zip'));

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      if (response.statusCode == 404) {
        throw AudioBibleUnavailableException(
            'This chapter\'s audio isn\'t available yet.');
      }
      if (response.statusCode != 200) {
        throw Exception(
            'Could not download chapter audio (HTTP ${response.statusCode}).');
      }

      final total = response.contentLength;
      var received = 0;
      final sink = tempZip.openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        _progressController.add(
            AudioBibleDownloadProgress(received: received, total: total));
      }
      await sink.close();

      // Same zip-slip-safe extraction pattern already established in
      // this codebase (see game_import_service.dart's importFromZipPath)
      // — every entry's resolved path must land inside targetDir.
      final bytes = await tempZip.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      await targetDir.create(recursive: true);
      for (final entry in archive) {
        final outPath = p.normalize(p.join(targetDir.path, entry.name));
        if (!p.isWithin(targetDir.path, outPath) && outPath != targetDir.path) {
          continue; // skip unsafe entries rather than fail the whole chapter
        }
        if (entry.isFile) {
          final outFile = File(outPath);
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(entry.content as List<int>);
        }
      }
    } catch (e) {
      // Clean up a partial extraction so a retry doesn't mistake it for
      // a completed download via isDownloaded()'s non-empty check.
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
      }
      rethrow;
    } finally {
      _progressController.add(null);
      if (await tempZip.exists()) {
        await tempZip.delete();
      }
      // Closed here — after the streamed response body (read in the try
      // block above) is guaranteed to be fully drained or the method
      // has already thrown past that point. http.Client's own docs
      // warn that closing while another async operation on it is still
      // running is undefined behavior, so this can't safely happen any
      // earlier than the same finally that's already cleaning up.
      client.close();
    }
  }

  /// Sorted local file paths for every verse in this chapter — natural
  /// numeric order (verse 2 before verse 10), not the lexicographic
  /// order `Directory.list()` would otherwise give (which would put
  /// "..._10.mp3" before "..._2.mp3"). Empty if not downloaded yet —
  /// call [ensureDownloaded] first.
  Future<List<File>> verseFilesFor(
      String langCode, int bookPosition, int chapterNumber) async {
    final dir = await _chapterDir(langCode, bookPosition, chapterNumber);
    if (!await dir.exists()) return [];
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File) files.add(entity);
    }
    int verseNumberOf(File f) {
      final match = RegExp(r'_(\d+)\.(mp3|wav)$').firstMatch(f.path);
      return match == null ? 0 : int.parse(match.group(1)!);
    }

    files.sort((a, b) => verseNumberOf(a).compareTo(verseNumberOf(b)));
    return files;
  }

  /// Plays every verse in this chapter back-to-back, as one continuous
  /// listen. Downloads first via [ensureDownloaded] if not already
  /// cached. Stops early (without error) if [stop] or another
  /// [playChapter] call supersedes this one mid-chapter.
  Future<void> playChapter(
      String langCode, int bookPosition, int chapterNumber) async {
    final myToken = ++_playToken;
    await ensureDownloaded(langCode, bookPosition, chapterNumber);
    if (myToken != _playToken) return; // superseded while downloading

    final files = await verseFilesFor(langCode, bookPosition, chapterNumber);
    for (final file in files) {
      if (myToken != _playToken) return;
      await _player.setFilePath(file.path);
      await _player.play();
      await _player.playerStateStream.firstWhere(
        (s) => s.processingState == ProcessingState.completed,
      );
    }
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();

  Future<void> stop() async {
    _playToken++;
    await _player.stop();
  }

  Stream<PlayerState> get stateStream => _player.playerStateStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Duration? get duration => _player.duration;
}
