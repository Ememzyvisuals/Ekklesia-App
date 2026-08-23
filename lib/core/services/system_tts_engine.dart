import 'dart:async';
import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Thrown when the device's own TTS engine never completes synthesis —
/// see the timeout note on [SystemTtsEngine.synthesizeToFile] for why
/// this is a real, confirmed failure mode, not a hypothetical one.
class SystemTtsTimeoutException implements Exception {
  const SystemTtsTimeoutException();
  @override
  String toString() =>
      'SystemTtsTimeoutException: the device TTS engine did not respond.';
}

/// English narration uses the device's own TTS voice (spec §20 — "do not
/// download an English neural model unnecessarily"), not a downloaded
/// model, not cloud. PROJECT_MIGRATION_AUDIT.md Phase 5.
class SystemTtsEngine {
  SystemTtsEngine._internal();
  static final SystemTtsEngine instance = SystemTtsEngine._internal();

  final FlutterTts _flutterTts = FlutterTts();
  bool _configured = false;

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _flutterTts.setLanguage('en-US');
    await _flutterTts.setSpeechRate(0.5); // flutter_tts's 0.5 ~= normal pace
    _configured = true;
  }

  /// Synthesizes [text] to a local WAV file and returns its path — same
  /// output shape as [LocalTtsEngine.synthesize] so tts_service.dart can
  /// treat every engine uniformly.
  ///
  /// Confirmed on a real device: hitting "Listen" on the English Bible
  /// hung indefinitely with no error, no timeout, no way out except
  /// force-closing the app. Root cause — `synthesizeToFile`'s Future only
  /// completes when the platform's native TTS engine fires a "synthesis
  /// complete" callback, and that callback is well-documented across
  /// flutter_tts issue trackers as simply never firing on a meaningful
  /// number of Android OEM TTS engines (Samsung's bundled engine and
  /// several older Google TTS versions among them) — the file, in some
  /// cases, is actually written successfully; the app just never finds
  /// out. A bounded timeout with a real error is infinitely better than
  /// an unbounded hang: at worst it's a wrong-but-fast failure that lets
  /// someone retry.
  ///
  /// Second, separate, real bug found and fixed here: `synthesizeToFile`'s
  /// second argument is documented by flutter_tts as a bare file NAME,
  /// not a path — its third, optional `isFullPath` argument defaults to
  /// `false`, and when false, the plugin's own native Android code
  /// resolves that "name" against ITS OWN internal directory
  /// (`context.getExternalFilesDir(null)`), completely ignoring whatever
  /// directory this Dart code assumes. This file was passing a bare
  /// `fileName` and then checking for the result at
  /// `p.join(outDir.path, fileName)` — `outDir` being path_provider's
  /// temporary/cache directory, a different directory than where
  /// flutter_tts actually wrote the file. That mismatch meant the
  /// `outFile.exists()` check below almost always failed even when
  /// synthesis genuinely succeeded, which is why "Could not generate
  /// audio" was reported happening "very frequently" for English —
  /// confirmed against flutter_tts's own issue tracker (a report showing
  /// the exact same "trying to combine the path I gave it to the
  /// internal path" symptom). Fixed by passing `isFullPath: true` and
  /// handing the plugin the exact path this code already computes and
  /// later checks, so both sides agree on where the file lives.
  Future<String> synthesizeToFile(String text) async {
    await _ensureConfigured();

    final cacheDir = await getTemporaryDirectory();
    final outDir = Directory(p.join(cacheDir.path, 'tts_output'));
    if (!await outDir.exists()) await outDir.create(recursive: true);
    final fileName = 'eng_${DateTime.now().microsecondsSinceEpoch}.wav';
    final outPath = p.join(outDir.path, fileName);

    try {
      // Long text (a full chapter) genuinely takes real synthesis time
      // even when working correctly — 45s gives real synthesis room
      // without leaving a person staring at a spinner indefinitely on
      // the actual failure case.
      await _flutterTts
          .synthesizeToFile(text, outPath, true)
          .timeout(const Duration(seconds: 45));
    } on TimeoutException {
      throw const SystemTtsTimeoutException();
    }

    final outFile = File(outPath);
    if (!await outFile.exists() || await outFile.length() == 0) {
      // The completion callback fired (so we got past the timeout) but
      // no real audio file resulted — a different, but equally real,
      // failure mode for the same underlying platform-channel
      // unreliability. Same treatment: a clear error over silence.
      throw const SystemTtsTimeoutException();
    }

    return outPath;
  }
}
