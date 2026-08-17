import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'tts_model_registry.dart';

/// Wraps sherpa-onnx's OfflineTts for the three on-device MMS languages
/// (yo/ha/pcm — see AppConfig.mmsOnnxAvailableLanguages).
///
/// Model load + generate + free all happen inside a spawned isolate per
/// call (see [_generateInIsolate] below), not held across calls the way
/// spec §45's ModelLifecycleManager originally described ("only one
/// language's model loaded at a time, reused until switched") — that
/// design assumed `generate()` was safe to call on the main isolate.
/// It isn't: sherpa_onnx's `generate()` is a synchronous, CPU-bound FFI
/// call that fully blocks whichever isolate calls it, including
/// Flutter's own frame rendering — on a real device, hitting Listen
/// visibly froze the entire app for the duration of synthesis, not just
/// showed a spinner. Moving generation to its own isolate keeps the UI
/// responsive at the cost of reloading the model fresh each call, which
/// is the right trade on the low-end Android hardware this app targets.
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
/// other on-device piece in this migration. The UI-freeze problem this
/// pass fixes is certain regardless (synchronous FFI always blocks its
/// isolate); the isolate-offload fix itself is the one piece of
/// today's changes most worth testing directly on a real device.
class LocalTtsEngine {
  LocalTtsEngine._internal();
  static final LocalTtsEngine instance = LocalTtsEngine._internal();

  /// Synthesizes [text] in [mmsCode] and writes the result to a WAV file
  /// under the app's cache directory, returning its path. Caller (
  /// tts_service.dart) wraps this path as `file://<path>` for
  /// AudioService to play — see AudioService's file:// branch.
  Future<String> synthesize({
    required String text,
    required String mmsCode,
  }) async {
    // Confirms the model is downloaded and gets its file paths before
    // handing off to the isolate — throws TtsModelNotReadyException
    // here, on the main isolate, so that specific, expected failure
    // reaches the UI the normal way rather than needing to cross an
    // isolate boundary itself.
    final info = await TtsModelRegistry.instance.status(mmsCode);
    if (!info.isReady ||
        info.localModelPath == null ||
        info.localTokensPath == null) {
      throw TtsModelNotReadyException(mmsCode);
    }

    final cacheDir = await getTemporaryDirectory();
    final outDir = Directory(p.join(cacheDir.path, 'tts_output'));
    if (!await outDir.exists()) await outDir.create(recursive: true);
    final outPath = p.join(
      outDir.path,
      '${mmsCode}_${DateTime.now().microsecondsSinceEpoch}.wav',
    );

    // `tts.generate(...)` is a synchronous, CPU-bound native (FFI) call
    // — not just "might be slow," but genuinely blocking: while it runs,
    // nothing else on this isolate executes at all, including Flutter's
    // own frame rendering and touch handling, and including any
    // `.timeout()` a caller might wrap around this — a Duration timer
    // can't fire on an isolate whose event loop is itself blocked. For
    // a full Bible chapter on real, low-end Android hardware, that's
    // real seconds-to-tens-of-seconds of a fully frozen UI, which is
    // indistinguishable from a hang to the person using it.
    //
    // Offloading via `compute()` runs this on a separate isolate, which
    // is why the whole load+generate+write sequence is repeated here in
    // a standalone top-level function instead of reusing the
    // already-loaded `_tts` above: sherpa_onnx's OfflineTts wraps a
    // native pointer, and native-resource objects generally can't be
    // sent across an isolate boundary — only plain data (the paths and
    // text below) can. The model gets loaded fresh inside the spawned
    // isolate each call; slightly more work per synthesis, but correct,
    // versus a UI that can't render or respond to touches for the
    // duration.
    //
    // Confidence note: this hasn't been run against a real compiled
    // build (sherpa_onnx's exact API surface here was already flagged
    // by this file's own prior comments as unverified against a live
    // package listing) — the UI-freeze problem itself is certain
    // (synchronous FFI calls always block their isolate, that's not
    // package-version-dependent), but this specific isolate-offload fix
    // is lower-confidence than the rest of today's fixes and is the one
    // most worth testing directly.
    final samples = await compute(_generateInIsolate, _GenerateRequest(
      modelPath: info.localModelPath!,
      tokensPath: info.localTokensPath!,
      text: text,
    ));

    await _writeWav(
      path: outPath,
      samples: samples.samples,
      sampleRate: samples.sampleRate,
    );

    return outPath;
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
      'TtsModelNotReadyException: no downloaded model for "$mmsCode". '
      'Prompt the user to download it first.';
}

/// Plain-data request for [_generateInIsolate] — every field must be
/// isolate-transferable (no native pointers, no class instances holding
/// FFI resources), which is exactly why this exists as its own type
/// instead of passing an OfflineTts instance directly.
class _GenerateRequest {
  const _GenerateRequest({
    required this.modelPath,
    required this.tokensPath,
    required this.text,
  });
  final String modelPath;
  final String tokensPath;
  final String text;
}

class _GenerateResult {
  const _GenerateResult({required this.samples, required this.sampleRate});
  final Float32List samples;
  final int sampleRate;
}

/// Runs entirely on a spawned isolate via `compute()` — loads its own
/// OfflineTts instance (can't reuse one created on the main isolate; see
/// the confidence note on [LocalTtsEngine.synthesize] above), generates,
/// and frees it before returning. Must be a top-level function (not a
/// method or closure) — that's a `compute()` requirement, not a style
/// choice.
Future<_GenerateResult> _generateInIsolate(_GenerateRequest request) async {
  final tts = OfflineTts(
    OfflineTtsConfig(
      model: OfflineTtsModelConfig(
        vits: OfflineTtsVitsModelConfig(
          model: request.modelPath,
          tokens: request.tokensPath,
        ),
        numThreads: 2,
      ),
    ),
  );
  try {
    // sid (speaker id) 0 -- these MMS checkpoints are single-speaker;
    // speed 1.0 -- on-device voices don't need the speed-correction
    // hack the old cloud YarnGPT engine required (see
    // PROJECT_MIGRATION_AUDIT.md Phase 5 — AudioService's speedForSource
    // no longer has a per-engine override at all, cloud or otherwise).
    final audio = tts.generate(text: request.text, sid: 0, speed: 1.0);
    return _GenerateResult(
        samples: audio.samples, sampleRate: audio.sampleRate);
  } finally {
    tts.free();
  }
}
