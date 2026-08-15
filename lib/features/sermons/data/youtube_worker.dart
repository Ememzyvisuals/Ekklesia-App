import 'dart:async';
import 'youtube_repository.dart';

/// Refreshes the YouTube cache periodically while the app is in the
/// foreground, and once immediately on start.
///
/// Honest scope note: this is NOT the OS-level background worker the spec's
/// "Background Workers" section describes (one that runs even when the app
/// is fully closed) — that needs the `workmanager` package plus Android
/// WorkManager constraints and iOS BGTaskScheduler registration, none of
/// which exist in this project yet. Building that without the actual
/// platform wiring would just be a worker that silently never fires.
/// Foreground-interval refresh is a real, working stand-in: it keeps the
/// Home dashboard's "current live program" reasonably fresh whenever
/// someone has the app open, which covers the common case. Wiring true
/// background refresh is a distinct follow-up.
class YoutubeWorker {
  YoutubeWorker({YoutubeRepository? repository})
      : _repository = repository ?? YoutubeRepository();

  final YoutubeRepository _repository;
  Timer? _timer;

  void start({Duration interval = const Duration(minutes: 10)}) {
    stop();
    _repository.refresh(); // immediate first pull
    _timer = Timer.periodic(interval, (_) => _repository.refresh());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
