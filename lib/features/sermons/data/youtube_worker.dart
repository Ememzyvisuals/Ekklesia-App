import 'dart:async';
import 'youtube_repository.dart';
import '../../../core/shared/result.dart';

/// Refreshes the YouTube cache periodically while the app is in the
/// foreground, and once immediately on start.
///
/// Honest scope note: this is NOT the OS-level background worker the spec's
/// "Background Workers" section describes (one that runs even when the app
/// is fully closed) — that needs the `workmanager` package plus Android
/// WorkManager constraints and iOS BGTaskScheduler registration, none of
/// which exist in this project yet. Foreground-interval refresh is a real,
/// working stand-in: it keeps the Home dashboard's "current live program"
/// reasonably fresh whenever someone has the app open. Wiring true
/// background refresh is a distinct follow-up.
class YoutubeWorker {
  YoutubeWorker({YoutubeRepository? repository})
      : _repository = repository ?? YoutubeRepository();

  final YoutubeRepository _repository;
  Timer? _timer;

  /// Set after every refresh attempt — the actual reason the last sync
  /// failed (invalid/misconfigured API key, quota exceeded, no
  /// internet, etc.), or null if the last attempt succeeded. Previously
  /// `_repository.refresh()` was called without ever reading its
  /// returned Result — a failure was computed correctly (see
  /// youtube_repository.dart, which does surface real HTTP status codes
  /// and bodies) and then thrown straight into the void: nothing ever
  /// displayed it, so the Live and Sermon Library screens just showed
  /// their normal empty state as if nothing had gone wrong at all.
  /// Confirmed on a real device: YouTube content never populated, with
  /// zero visible indication why. This makes the real reason visible to
  /// whatever screen wants to check it.
  static String? lastError;

  void start({Duration interval = const Duration(minutes: 10)}) {
    stop();
    _refreshAndCaptureError(); // immediate first pull
    _timer = Timer.periodic(interval, (_) => _refreshAndCaptureError());
  }

  Future<void> _refreshAndCaptureError() async {
    final result = await _repository.refresh();
    switch (result) {
      case ResultFailure(failure: final f):
        lastError = f.message;
      case ResultSuccess():
        lastError = null;
      case ResultLoading():
        break;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
