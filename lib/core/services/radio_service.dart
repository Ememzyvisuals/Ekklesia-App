import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

import '../config/app_config.dart';

/// Now-playing metadata from stat1.dclm.org's AzuraCast API — current
/// song title/artist/art and live listener count. Nothing in the official
/// radio-app-v1 site does anything with this beyond printing it into a
/// couple of <span> tags; showing it in this app's own UI is the actual
/// "surpass it" case, not a reimplementation for its own sake.
class DclmNowPlaying {
  DclmNowPlaying(
      {required this.artist,
      required this.title,
      required this.artUrl,
      required this.listeners});
  final String artist;
  final String title;
  final String artUrl;
  final int listeners;
}

/// Handles DCLM radio streaming — plain `just_audio` playback, no
/// `just_audio_background`/MediaItem tagging (see pubspec.yaml's comment
/// on the removed dependency for the full reasoning): six straight
/// rounds of a device-confirmed `LateInitializationError` across every
/// audio feature in the app, not just this one, made clear that
/// dependency was the actual problem, not a misconfiguration to keep
/// chasing. Real, known cost of removing it: no lock-screen/notification
/// playback controls, and the stream may stop when the screen locks or
/// the app backgrounds on some devices — a real regression from the
/// original goal, but a working radio without lock-screen controls is a
/// far better outcome than a radio that has never once actually played
/// on the person's own device.
class RadioService {
  RadioService._internal();
  static final RadioService instance = RadioService._internal();

  final AudioPlayer _player = AudioPlayer();
  AudioPlayer get player => _player;

  String? _currentLanguage;
  String? get currentLanguage => _currentLanguage;

  Timer? _nowPlayingTimer;
  final _nowPlayingController = StreamController<DclmNowPlaying?>.broadcast();
  Stream<DclmNowPlaying?> get nowPlayingStream => _nowPlayingController.stream;

  Future<void> playLanguage(String languageKey) async {
    final url = AppConfig.dclmStreams[languageKey] ??
        AppConfig.dclmExtraStreams[languageKey];
    if (url == null) {
      throw Exception('No DCLM stream configured for "$languageKey"');
    }

    _currentLanguage = languageKey;

    // Both calls below are unbounded native/platform operations with no
    // timeout of their own — confirmed on a real device to hang forever
    // (endless "Tap to Play" spinner, never an error) when the stream
    // host is slow to respond or the connection stalls mid-handshake,
    // the exact same "unbounded native call can hang forever" pattern
    // already fixed for TTS (system_tts_engine.dart,
    // local_tts_engine.dart). Network Diagnostics reaching the stream
    // host fine doesn't rule this out — a raw socket connecting is a
    // different operation from just_audio actually opening and starting
    // to decode the stream. Bounded to a real timeout so a stall becomes
    // a fast, visible error instead of an infinite spinner; live_screen.dart
    // already has the friendly-message handling for a TimeoutException
    // here, it just never had one to catch.
    //
    // Bumped from 15s to 30s — confirmed on a real device with weak
    // (1-2 bar) signal that the connection genuinely can take longer
    // than 15s to fully establish while still eventually working fine
    // (audio was heard playing normally even after the old 15s timeout
    // had already fired and shown an incorrect "you're offline" error).
    // 30s is a real tradeoff (a genuinely dead connection now takes
    // twice as long to report as failed) accepted deliberately in
    // favor of not misreporting a slow-but-working connection as
    // broken.
    await _player
        .setAudioSource(AudioSource.uri(Uri.parse(url)))
        .timeout(const Duration(seconds: 30));

    await _player.play().timeout(const Duration(seconds: 30));
    _startNowPlayingPolling(languageKey);
  }

  /// Polls every 60s — matches the official site's own cadence (see
  /// index.php's `setTimeout(getAPI, 60000)`), not an arbitrary choice.
  void _startNowPlayingPolling(String languageKey) {
    _nowPlayingTimer?.cancel();
    _fetchNowPlaying(languageKey);
    _nowPlayingTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => _fetchNowPlaying(languageKey));
  }

  Future<void> _fetchNowPlaying(String languageKey) async {
    final stationId = AppConfig.dclmNowPlayingStationIds[languageKey];
    if (stationId == null) {
      _nowPlayingController.add(null);
      return;
    }
    try {
      final response = await http
          .get(Uri.parse('${AppConfig.dclmNowPlayingBaseUrl}/$stationId'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        _nowPlayingController.add(null);
        return;
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final song = (json['now_playing'] as Map<String, dynamic>?)?['song']
          as Map<String, dynamic>?;
      final listeners =
          (json['listeners'] as Map<String, dynamic>?)?['current'] as int? ?? 0;
      if (song == null) {
        _nowPlayingController.add(null);
        return;
      }
      _nowPlayingController.add(DclmNowPlaying(
        artist: song['artist'] as String? ?? 'DCLM Radio',
        title: song['title'] as String? ?? 'On Air',
        artUrl: song['art'] as String? ?? '',
        listeners: listeners,
      ));
    } catch (_) {
      // Metadata is decorative — never let a failed poll disrupt playback.
      _nowPlayingController.add(null);
    }
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();

  Future<void> stop() async {
    await _player.stop();
    _currentLanguage = null;
    _nowPlayingTimer?.cancel();
    _nowPlayingTimer = null;
    _nowPlayingController.add(null);
  }

  /// Live streams have no fixed duration/position — this just exposes
  /// play/pause/buffering state for the UI.
  Stream<PlayerState> get stateStream => _player.playerStateStream;

  Future<void> dispose() async {
    _nowPlayingTimer?.cancel();
    await _nowPlayingController.close();
    await _player.dispose();
  }
}
