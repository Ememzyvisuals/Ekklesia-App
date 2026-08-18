import 'dart:async';
import 'dart:io';

/// Lightweight, periodic raw-connectivity check — deliberately not a
/// full re-run of every NetworkDiagnostics endpoint (that's a heavier,
/// on-demand debugging tool; this is a cheap, continuous background
/// signal for the small always-visible offline indicator). A single DNS
/// lookup every 15 seconds is negligible battery/data cost.
class ConnectivityMonitor {
  ConnectivityMonitor._internal() {
    _check();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _check());
  }
  static final ConnectivityMonitor instance = ConnectivityMonitor._internal();

  final _controller = StreamController<bool>.broadcast();
  Timer? _timer;
  bool _lastKnown = true;

  Stream<bool> get isOnlineStream => _controller.stream;
  bool get lastKnown => _lastKnown;

  Future<void> _check() async {
    bool online;
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 5));
      online = result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      online = false;
    }
    _lastKnown = online;
    _controller.add(online);
  }

  /// Called by the diagnostics screen's manual refresh, or after
  /// resolving a connectivity issue, to get an immediate update rather
  /// than waiting for the next 15-second tick.
  Future<void> checkNow() => _check();
}
