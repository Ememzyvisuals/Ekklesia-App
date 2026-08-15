import '../config/app_config.dart';
import 'audio_service.dart';
import 'local_tts_engine.dart';
import 'system_tts_engine.dart';
import 'tts_error_logger.dart';

enum EkklesiaLanguage { english, hausa, igbo, pidgin, yoruba }

extension EkklesiaLanguageCode on EkklesiaLanguage {
  String get code {
    switch (this) {
      case EkklesiaLanguage.english:
        return 'english';
      case EkklesiaLanguage.hausa:
        return 'hausa';
      case EkklesiaLanguage.igbo:
        return 'igbo';
      case EkklesiaLanguage.pidgin:
        return 'pidgin';
      case EkklesiaLanguage.yoruba:
        return 'yoruba';
    }
  }

  /// MMS ISO 639-3 code for the on-device engine, or null for languages
  /// that don't go through LocalTtsEngine at all (English uses system
  /// TTS; Igbo has no voice — see AppConfig.ttsLanguageToMmsCode's doc
  /// comment for why).
  String? get mmsCode => AppConfig.ttsLanguageToMmsCode[code];
}

/// Result of a TTS generation — always a local `file://` path now
/// (PROJECT_MIGRATION_AUDIT.md Phase 5: no cloud engine produces a
/// remote URL anymore). [source] is kept for AudioService's per-source
/// playback-speed lookup.
class TtsResult {
  TtsResult({required this.audioUrl, required this.source});
  final String audioUrl;
  final AudioSource source;
}

/// Thrown when [TtsService.synthesizeWithRetry] is called for a language
/// with no voice available at all (Igbo — see
/// AppConfig.ttsLanguageToMmsCode's doc comment: no small,
/// sherpa-onnx-compatible, validated Igbo model exists anywhere,
/// checked extensively). Not retryable, not a fallback-to-cloud
/// situation — there's nowhere left to fall back to. Callers should
/// hide/disable the "Listen" control for this language entirely rather
/// than let a user hit this by tapping a visible button — see
/// bible_screen.dart's language-aware Listen button.
class TtsLanguageUnavailableException implements Exception {
  TtsLanguageUnavailableException(this.language);
  final EkklesiaLanguage language;
  @override
  String toString() =>
      'TtsLanguageUnavailableException: no voice available for '
      '${language.code} — this is a real, documented gap, not a bug. '
      'See AppConfig.ttsLanguageToMmsCode.';
}

/// Thrown when generation fails for a reason other than "no voice
/// exists" or "model not downloaded" (that's [TtsModelNotReadyException]
/// from local_tts_engine.dart, surfaced as-is, not wrapped, so the UI
/// can route straight to the download picker).
class TtsGenerationException implements Exception {
  TtsGenerationException(this.message);
  final String message;
  @override
  String toString() => 'TtsGenerationException: $message';
}

/// Routes text-to-speech requests to the correct on-device engine per
/// language. PROJECT_MIGRATION_AUDIT.md Phase 5 — rewritten to remove
/// GradioClient/WazobiaVoice/YarnGPT cloud calls entirely, by explicit
/// instruction: this app has zero cloud dependency for speech.
///
///   English            -> SystemTtsEngine (device TTS, spec §20)
///   Yoruba/Hausa/Pidgin -> LocalTtsEngine (downloaded MMS ONNX model —
///                          see TtsModelRegistry; throws
///                          [TtsModelNotReadyException] if not
///                          downloaded yet, never auto-downloads)
///   Igbo                -> always throws
///                          [TtsLanguageUnavailableException] — no
///                          fallback, no cloud, just genuinely
///                          unavailable until a real on-device model
///                          exists (see that exception's doc comment).
class TtsService {
  TtsService._internal();
  static final TtsService instance = TtsService._internal();

  Future<TtsResult> synthesize({
    required String text,
    required EkklesiaLanguage language,
  }) {
    return synthesizeWithRetry(text: text, language: language);
  }

  /// "WithRetry" name kept from the pre-Phase-5 cloud version for
  /// call-site compatibility (BibleTTSQueue, ai_assistant_screen.dart) —
  /// on-device synthesis is a local, synchronous-ish computation with no
  /// network flakiness to retry against, so this no longer actually
  /// retries anything. Left named this way rather than churning every
  /// caller for a rename that changes no behavior they depend on.
  Future<TtsResult> synthesizeWithRetry({
    required String text,
    required EkklesiaLanguage language,
  }) async {
    if (language == EkklesiaLanguage.igbo) {
      throw TtsLanguageUnavailableException(language);
    }

    try {
      if (language == EkklesiaLanguage.english) {
        final path = await SystemTtsEngine.instance.synthesizeToFile(text);
        return TtsResult(
            audioUrl: 'file://$path', source: AudioSource.onDeviceTts);
      }

      final mmsCode = language.mmsCode;
      if (mmsCode == null) {
        // Defensive — every non-English, non-Igbo EkklesiaLanguage value
        // must have an mmsCode entry; this only fires if that mapping
        // and this switch ever drift apart.
        throw TtsGenerationException(
            'No on-device engine configured for ${language.code}.');
      }

      final path = await LocalTtsEngine.instance
          .synthesize(text: text, mmsCode: mmsCode);
      return TtsResult(
          audioUrl: 'file://$path', source: AudioSource.onDeviceTts);
    } on TtsModelNotReadyException {
      rethrow; // UI routes this straight to the download picker.
    } catch (e) {
      await TtsErrorLogger.instance.logFailure(
        source: language.code,
        message: e.toString(),
      );
      throw TtsGenerationException('Could not generate audio: $e');
    }
  }

  /// Splits [text] into speakable chunks and synthesizes each in order —
  /// see [BibleTTSQueue] for chapter-length text where look-ahead
  /// prefetch matters; this is the simple sequential version used by
  /// the AI assistant's shorter replies.
  Stream<TtsResult> synthesizeChunks({
    required String text,
    required EkklesiaLanguage language,
  }) async* {
    for (final chunk in chunkText(text)) {
      if (chunk.trim().isEmpty) continue;
      yield await synthesizeWithRetry(text: chunk, language: language);
    }
  }

  /// Splits [text] into pieces no longer than
  /// [AppConfig.onDeviceTtsMaxChars], breaking on sentence boundaries
  /// first, then falling back to whitespace, so a chunk never cuts off
  /// mid-word if avoidable. On-device VITS models handle much longer
  /// input than the old cloud engines could (no fixed-length-clip
  /// truncation bug to work around), but chunking is still worth
  /// keeping for look-ahead prefetch (BibleTTSQueue) and to bound how
  /// long a single synthesis call blocks the UI.
  List<String> chunkText(String text) =>
      _splitIntoChunks(text, AppConfig.onDeviceTtsMaxChars);

  List<String> _splitIntoChunks(String text, int maxChars) {
    final trimmed = text.trim();
    if (trimmed.length <= maxChars) return [trimmed];

    final sentences = trimmed
        .split(RegExp(r'(?<=[.!?])\s+'))
        .where((s) => s.trim().isNotEmpty)
        .toList();

    final chunks = <String>[];
    var current = StringBuffer();

    void flush() {
      if (current.isNotEmpty) {
        chunks.add(current.toString().trim());
        current = StringBuffer();
      }
    }

    for (final sentence in sentences) {
      if (sentence.length > maxChars) {
        flush();
        final words = sentence.split(RegExp(r'\s+'));
        var wordChunk = StringBuffer();
        for (final word in words) {
          final candidateLength =
              wordChunk.length + (wordChunk.isEmpty ? 0 : 1) + word.length;
          if (candidateLength > maxChars && wordChunk.isNotEmpty) {
            chunks.add(wordChunk.toString().trim());
            wordChunk = StringBuffer();
          }
          if (wordChunk.isNotEmpty) wordChunk.write(' ');
          wordChunk.write(word);
        }
        if (wordChunk.isNotEmpty) chunks.add(wordChunk.toString().trim());
        continue;
      }

      final candidateLength =
          current.length + (current.isEmpty ? 0 : 1) + sentence.length;
      if (candidateLength > maxChars && current.isNotEmpty) {
        flush();
      }
      if (current.isNotEmpty) current.write(' ');
      current.write(sentence);
    }
    flush();

    return chunks;
  }
}
