import '../../../core/services/tts_service.dart';

/// Closes the gap documented in BIBLE_IMPORT_NOTES.md: previously, chapter
/// audio generated strictly one chunk at a time — chunk N+1's network call
/// only started after chunk N had *finished playing* (because the
/// consuming `await for` loop in AudioService.playQueue doesn't pull the
/// next stream item until the current one's playback completes). That
/// meant real dead air between chunks on anything longer than one chunk.
///
/// This queue decouples generation from playback: it kicks off chunk N+1's
/// generation as soon as chunk N's generation finishes (not when it
/// finishes *playing*), maintaining a small look-ahead buffer. By the time
/// playback of chunk N ends, chunk N+1 is usually already sitting in the
/// buffer ready to go.
///
/// Deliberately NOT a full implementation of the spec's
/// BibleTTSQueue/QueueManager/PlaybackManager/ChunkGenerator/
/// AudioScheduler/PrefetchManager/RetryManager/PlaybackLogger split —
/// retry lives in TtsService.synthesizeWithRetry (shared with every other
/// TTS caller, not Bible-specific), logging lives in TtsErrorLogger (same
/// reasoning), and playback scheduling is still AudioService.playQueue.
/// This class's actual job is narrow and real: look-ahead prefetch. Giving
/// it seven collaborating classes for that one job would be the "never
/// build fake code" rule's inverse failure mode — scaffolding with no
/// behavior behind most of it.
class BibleTTSQueue {
  BibleTTSQueue({this.prefetchDepth = 1});

  /// How many chunks ahead of what's currently playing to keep
  /// generating. 1 means "always have the next chunk ready" — enough to
  /// eliminate dead air for normal chapter lengths without hammering the
  /// TTS Space with a large burst of simultaneous requests.
  final int prefetchDepth;

  /// Splits [text] into TTS-sized chunks and yields each [TtsResult] in
  /// order, with up to [prefetchDepth] chunks generating concurrently
  /// ahead of what's been yielded so far.
  Stream<TtsResult> stream({
    required String text,
    required EkklesiaLanguage language,
  }) async* {
    final chunkTexts = TtsService.instance
        .chunkText(text)
        .where((c) => c.trim().isNotEmpty)
        .toList();
    if (chunkTexts.isEmpty) return;

    // One in-flight Future per chunk, started eagerly up to the
    // look-ahead depth. Awaiting pending[i] before it's needed just
    // waits for work that's already underway — it doesn't delay the
    // start of generation the way sequential await-then-generate would.
    //
    // `started` tracks how many chunks have had generation kicked off
    // so far (always >= the number actually served/awaited). The fill
    // condition below is a genuine *sliding* window relative to how many
    // chunks have been served, not a one-time cap — an earlier version
    // of this method checked `pending.length <= prefetchDepth`, which
    // only ever filled the buffer once and then threw a RangeError on
    // any chapter with more chunks than prefetchDepth + 1 (i.e. almost
    // every real chapter). Keep the window check relative to `served`.
    final pending = <Future<TtsResult>>[];
    var started = 0;

    void fillPending(int served) {
      while (
          started < chunkTexts.length && started < served + prefetchDepth + 1) {
        pending.add(
          TtsService.instance.synthesizeWithRetry(
              text: chunkTexts[started], language: language),
        );
        started++;
      }
    }

    fillPending(0);

    for (var served = 0; served < chunkTexts.length; served++) {
      final result = await pending[served];
      // Now that chunk `served` is ready (not necessarily *played* yet —
      // AudioService will play it after this yields, on its own time),
      // top up the look-ahead buffer with the next not-yet-started chunk.
      fillPending(served + 1);
      yield result;
    }
  }
}
