import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'tts_model_registry.dart';

/// Wraps sherpa-onnx's OfflineTts for the three on-device MMS languages
/// (yo/ha/pcm — see AppConfig.mmsOnnxAvailableLanguages). Spec §45's
/// ModelLifecycleManager: only one language's model is loaded into
/// memory at a time, unloaded before the next one loads, so switching
/// reading language doesn't accumulate multiple ONNX sessions in RAM —
/// real concern on the low-end Android hardware this app targets.
///
/// PROJECT_MIGRATION_AUDIT.md Phase 5. No cloud fallback anywhere in
/// this class or its caller (tts_service.dart) — if a model isn't
/// downloaded, generation throws [TtsModelNotReadyException] rather
/// than silently reaching for a network call. This app has zero cloud
/// dependency for speech, by explicit instruction — Igbo simply has no
/// voice available (see tts_service.dart's TtsLanguageUnavailableException)
/// rather than falling back anywhere.
///
/// NOTE: sherpa_onnx's exact Dart API surface (OfflineTts/
/// OfflineTtsConfig/OfflineTtsModelConfig/OfflineTtsVitsModelConfig
/// constructor shapes) is written here to match the patterns documented
/// across k2-fsa's own Flutter examples and this project's own Kaggle
/// notebook's Python round-trip test — it has not been checked against
/// a live pub.dev package listing or compiled, same caveat as every
/// other on-device piece in this migration.
class LocalTtsEngine {
  LocalTtsEngine._internal();
  static final LocalTtsEngine instance = LocalTtsEngine._internal();

  String? _loadedLanguage;
  OfflineTts? _tts;

  /// Loads [mmsCode]'s model if not already the active one, unloading
  /// whatever was loaded before. Throws [TtsModelNotReadyException] if
  /// the model hasn't been downloaded yet (see [TtsModelRegistry]) —
  /// callers should check status / prompt a download before calling
  /// [synthesize], not rely on this to trigger one implicitly. Silent
  /// auto-download here would mean generating audio could unexpectedly
  /// start a multi-hundred-MB download on a metered connection.
  Future<void> _ensureLoaded(String mmsCode) async {
    if (_loadedLanguage == mmsCode && _tts != null) return;

    final info = await TtsModelRegistry.instance.status(mmsCode);
    if (!info.isReady ||
        info.localModelPath == null ||
        info.localTokensPath == null) {
      throw TtsModelNotReadyException(mmsCode);
    }

    _tts?.free();
    _tts = null;
    _loadedLanguage = null;

    _tts = OfflineTts(
      OfflineTtsConfig(
        model: OfflineTtsModelConfig(
          vits: OfflineTtsVitsModelConfig(
            model: info.localModelPath!,
            tokens: info.localTokensPath!,
          ),
          numThreads: 2,
        ),
      ),
    );
    _loadedLanguage = mmsCode;
  }

  /// Synthesizes [text] in [mmsCode] and writes the result to a WAV file
  /// under the app's cache directory, returning its path. Caller (
  /// tts_service.dart) wraps this path as `file://<path>` for
  /// AudioService to play — see AudioService's file:// branch.
  Future<String> synthesize({
    required String text,
    required String mmsCode,
  }) async {
    await _ensureLoaded(mmsCode);
    final tts = _tts!;

    // sid (speaker id) 0 -- these MMS checkpoints are single-speaker;
    // speed 1.0 -- on-device voices don't need the speed-correction
    // hack the old cloud YarnGPT engine required (see
    // PROJECT_MIGRATION_AUDIT.md Phase 5 — AudioService's speedForSource
    // no longer has a per-engine override at all, cloud or otherwise).
    final audio = tts.generate(text: text, sid: 0, speed: 1.0);

    final cacheDir = await getTemporaryDirectory();
    final outDir = Directory(p.join(cacheDir.path, 'tts_output'));
    if (!await outDir.exists()) await outDir.create(recursive: true);
    final outPath = p.join(
      outDir.path,
      '${mmsCode}_${DateTime.now().microsecondsSinceEpoch}.wav',
    );

    await _writeWav(
      path: outPath,
      samples: audio.samples,
      sampleRate: audio.sampleRate,
    );

    return outPath;
  }

  /// Releases the currently loaded model — call under memory pressure or
  /// when TTS won't be needed for a while (spec §44's "unload models
  /// when memory pressure requires it").
  void unload() {
    _tts?.free();
    _tts = null;
    _loadedLanguage = null;
  }

  /// Encodes 32-bit float PCM samples (sherpa-onnx's native output) as a
  /// standard 16-bit PCM WAV file — the format just_audio/most platform
  /// audio decoders expect, rather than shipping raw floats.
  Future<void> _writeWav({
    required String path,
    required Float32List samples,
    required int sampleRate,
  }) async {
    final pcm16 = Int16List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0);
      pcm16[i] = (clamped * 32767).round();
    }

    final dataBytes = pcm16.buffer.asUint8List();
    final byteRate = sampleRate * 2; // mono, 16-bit
    const blockAlign = 2;

    final header = BytesBuilder();
    void writeString(String s) => header.add(s.codeUnits);
    void writeUint32(int v) => header.add([
          v & 0xff,
          (v >> 8) & 0xff,
          (v >> 16) & 0xff,
          (v >> 24) & 0xff,
        ]);
    void writeUint16(int v) => header.add([v & 0xff, (v >> 8) & 0xff]);

    writeString('RIFF');
    writeUint32(36 + dataBytes.length);
    writeString('WAVE');
    writeString('fmt ');
    writeUint32(16); // PCM fmt chunk size
    writeUint16(1); // PCM format
    writeUint16(1); // mono
    writeUint32(sampleRate);
    writeUint32(byteRate);
    writeUint16(blockAlign);
    writeUint16(16); // bits per sample
    writeString('data');
    writeUint32(dataBytes.length);

    final file = File(path);
    final sink = file.openWrite();
    sink.add(header.toBytes());
    sink.add(dataBytes);
    await sink.close();
  }
}

/// Thrown when [LocalTtsEngine.synthesize] is called for a language whose
/// model hasn't been downloaded yet. Carries [mmsCode] so the UI can
/// route straight to that language's entry in the voice-download picker
/// rather than a generic error.
class TtsModelNotReadyException implements Exception {
  TtsModelNotReadyException(this.mmsCode);
  final String mmsCode;
  @override
  String toString() =>
      'TtsModelNotReadyException: no downloaded model for "$mmsCode" — '
      'prompt the user to download it first.';
}
