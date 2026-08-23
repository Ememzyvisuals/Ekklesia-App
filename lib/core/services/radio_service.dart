import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../config/app_config.dart';

/// Now-playing metadata from stat1.dclm.org's AzuraCast API — current
/// song title/artist/art and live listener count. Nothing in the official
/// radio-app-v1 site does anything with this beyond printing it into a
/// couple of <span> tags; showing it against real lock-screen media
/// controls (which this app has and the plain website obviously can't)
/// is the actual "surpass it" case, not a reimplementation for its own
/// sake.
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

/// Handles DCLM radio streaming specifically — reliable background/
/// lock-screen playback is the core differentiator over the official
/// DCLM app, so this gets its own dedicated player (separate from the
/// TTS playback in the main AudioService) with proper MediaItem tags
/// so Android/iOS show correct lock-screen art/title and don't kill the
/// stream when the screen locks.
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
    await _player
        .setAudioSource(
          AudioSource.uri(
            Uri.parse(url),
            tag: MediaItem(
              id: url,
              album: 'DCLM Radio',
              title: 'DCLM Radio: ${_displayName(languageKey)}',
              // Station art — real DCLM branding (Deeper Life Bible Church's
              // own emblem), not a placeholder: pulled directly from the
              // official radio.dclm.org web player's own default now-playing
              // artwork (assets/img/album-art/d.png there), same file used
              // twice under different names (favicon.png too) confirming
              // it's their actual default fallback art, not one-off filler.
              // Dynamic per-track art (the AzuraCast now-playing API's
              // song.art field, already fetched in _fetchNowPlaying below)
              // isn't wired to the lock-screen thumbnail yet — that needs
              // audio_service's mediaItem-update API, more machinery than
              // just_audio_background alone provides; using the static
              // station logo is a real improvement over no art at all, not
              // the final state.
              artUri: Uri.parse('asset:///assets/images/dclm_radio_art.png'),
            ),
          ),
        )
        .timeout(const Duration(seconds: 15));

    await _player.play().timeout(const Duration(seconds: 15));
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

  String _displayName(String key) => AppConfig.dclmLanguageLabels[key] ?? key;

  Future<void> dispose() async {
    _nowPlayingTimer?.cancel();
    await _nowPlayingController.close();
    await _player.dispose();
  }
}
