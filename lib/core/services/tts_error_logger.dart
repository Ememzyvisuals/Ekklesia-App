import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Logs on-device TTS generation failures to a local, rotating log file
/// instead of a remote collection — the app is offline-first, so there's
/// no server to ship these to. Kept as a file (not just `debugPrint`)
/// because it's still useful to be able to ask a user experiencing
/// repeated failures to share `tts_errors.log` for debugging, without
/// needing any analytics/logging infrastructure.
///
/// CleanupWorker prunes this file's old entries on its regular pass (see
/// cleanup_worker.dart) the same way it used to prune the Firestore
/// `worker_logs` collection.
///
/// Every call is fire-and-forget and swallows its own errors: a logging
/// failure must never be the reason TTS playback breaks.
class TtsErrorLogger {
  TtsErrorLogger._internal();
  static final TtsErrorLogger instance = TtsErrorLogger._internal();

  static const _maxEntries = 500;

  Future<File> _logFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/tts_errors.log');
  }

  Future<void> logFailure({
    required String source, // EkklesiaLanguage.code, e.g. 'yoruba'
    required String message,
  }) async {
    try {
      final file = await _logFile();
      final entry = jsonEncode({
        'level': 'error',
        'event': 'failed',
        'source': source,
        'message': message,
        'created_at': DateTime.now().toIso8601String(),
      });
      await file.writeAsString('$entry\n',
          mode: FileMode.append, flush: false);
      await _trimIfNeeded(file);
    } catch (_) {
      // Logging must never be the reason playback fails harder — if this
      // write fails (permissions, disk full, whatever), just drop it.
    }
  }

  /// Keeps the file from growing unbounded — trims to the most recent
  /// [_maxEntries] lines whenever it's written to.
  Future<void> _trimIfNeeded(File file) async {
    final lines = await file.readAsLines();
    if (lines.length <= _maxEntries) return;
    final trimmed = lines.sublist(lines.length - _maxEntries);
    await file.writeAsString('${trimmed.join('\n')}\n');
  }

  /// Deletes log entries older than [maxAge] — called by CleanupWorker's
  /// regular housekeeping pass.
  Future<void> pruneOlderThan(Duration maxAge) async {
    try {
      final file = await _logFile();
      if (!await file.exists()) return;
      final cutoff = DateTime.now().subtract(maxAge);
      final lines = await file.readAsLines();
      final kept = lines.where((line) {
        try {
          final data = jsonDecode(line) as Map<String, dynamic>;
          final createdAt = DateTime.parse(data['created_at'] as String);
          return createdAt.isAfter(cutoff);
        } catch (_) {
          return false; // malformed line — drop it
        }
      }).toList();
      await file.writeAsString(
          kept.isEmpty ? '' : '${kept.join('\n')}\n');
    } catch (_) {
      // Best-effort housekeeping — never surface this to the user.
    }
  }
}
