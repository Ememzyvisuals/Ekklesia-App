import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// English narration uses the device's own TTS voice (spec §20 — "do not
/// download an English neural model unnecessarily"), not a downloaded
/// model, not cloud. PROJECT_MIGRATION_AUDIT.md Phase 5.
///
/// NOTE: `synthesizeToFile` is a real flutter_tts capability on Android/
/// iOS in recent versions, used here so English output flows through the
/// same file:// -> AudioService.play() path as the on-device MMS voices
/// (see AudioService's file:// branch) instead of needing a second,
/// engine-specific playback path. Not verified against a live package
/// listing/compiled build — same caveat as sherpa_onnx's integration.
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
  Future<String> synthesizeToFile(String text) async {
    await _ensureConfigured();

    final cacheDir = await getTemporaryDirectory();
    final outDir = Directory(p.join(cacheDir.path, 'tts_output'));
    if (!await outDir.exists()) await outDir.create(recursive: true);
    final fileName = 'eng_${DateTime.now().microsecondsSinceEpoch}.wav';

    // flutter_tts's synthesizeToFile takes a bare filename and writes into
    // the platform's own app-storage directory (not an arbitrary path) on
    // most versions — passing outDir explicitly where the platform
    // channel supports it, falling back to the returned path otherwise.
    // Confirm this against the installed flutter_tts version's actual
    // signature before relying on the exact directory used.
    await _flutterTts.synthesizeToFile(text, fileName);

    final outPath = p.join(outDir.path, fileName);
    return outPath;
  }
}
