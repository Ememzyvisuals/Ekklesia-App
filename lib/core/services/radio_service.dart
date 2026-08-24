import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../config/app_config.dart';

/// Tracks whether `JustAudioBackground.init()` (called once at app
/// startup in main.dart) actually succeeded, and gives [RadioService] a
/// way to retry it — with a much more generous timeout — before ever
/// creating a MediaItem-tagged [AudioPlayer], instead of assuming
/// startup's attempt worked and finding out the hard way.
///
/// Real, confirmed bug this fixes: main.dart's startup call is wrapped
/// in a short timeout (previously 5s, since bumped to 12s) so a slow
/// cold start can't freeze the splash screen forever — but a genuine
/// timeout there was being silently swallowed with zero record of it,
/// so RadioService went on to build a player assuming background audio
/// setup had succeeded. Confirmed on a real device: the very first
/// radio playback attempt after a timed-out init threw
/// `LateInitializationError: Field '_audioHandler@...' has not been
/// initialized` — thrown by just_audio_background's own internals, not
/// this app's code, the moment anything tried to actually use it.
class JustAudioBackgroundInit {
  JustAudioBackgroundInit._();

  static bool _succeeded = false;

  static void markSucceeded() {
    _succeeded = true;
  }

  /// Called from [RadioService.playLanguage] before it builds its
  /// MediaItem-tagged [AudioPlayer]. A no-op if startup's attempt
  /// already succeeded (the overwhelmingly common case). If it hadn't,
  /// retries here with a longer allowance — 20s, versus main.dart's 12s
  /// — since this is now blocking one explicit "press play" action
  /// rather than the entire app's startup, a much more acceptable place
  /// to spend a few extra seconds getting it right.
  static Future<void> ensureInitialized() async {
    if (_succeeded) return;
    try {
      await JustAudioBackground.init(
        androidNotificationChannelId: 'com.ememzyvisuals.ekklesia.audio',
        androidNotificationChannelName: 'Ekklesia Audio',
        androidNotificationOngoing: true,
      ).timeout(const Duration(seconds: 20));
      _succeeded = true;
    } catch (_) {
      // Still couldn't set it up. Left unmarked so the next playback
      // attempt tries again rather than giving up permanently for the
      // rest of the app session — and playLanguage() below still
      // proceeds either way, since audio can work without lock-screen
      // controls, it just won't have them this time.
    }
  }
}

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

    // Must happen before building a MediaItem-tagged AudioSource below —
    // see JustAudioBackgroundInit's doc comment for the real, confirmed
    // LateInitializationError this prevents.
    await JustAudioBackgroundInit.ensureInitialized();

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
            // Only attach the MediaItem tag (lock-screen art/title) if
            // background audio setup genuinely succeeded above — a tag
            // is exactly what triggers just_audio_background's internal
            // handler, which is the part that was crashing with
            // LateInitializationError when setup hadn't actually
            // finished. Without a tag, playback still works, just
            // without lock-screen controls — a real degradation, but a
            // silent one instead of a crash, on whatever rare device/
            // cold-start combination still can't get background audio
            // set up even after the retry above.
            tag: JustAudioBackgroundInit._succeeded
                ? MediaItem(
                    id: url,
                    album: 'DCLM Radio',
                    title: 'DCLM Radio: ${_displayName(languageKey)}',
                    // Station art — real DCLM branding (Deeper Life Bible
                    // Church's own emblem), not a placeholder: pulled
                    // directly from the official radio.dclm.org web
                    // player's own default now-playing artwork
                    // (assets/img/album-art/d.png there), same file used
                    // twice under different names (favicon.png too)
                    // confirming it's their actual default fallback art,
                    // not one-off filler. Dynamic per-track art (the
                    // AzuraCast now-playing API's song.art field,
                    // already fetched in _fetchNowPlaying below) isn't
                    // wired to the lock-screen thumbnail yet — that
                    // needs audio_service's mediaItem-update API, more
                    // machinery than just_audio_background alone
                    // provides; using the static station logo is a real
                    // improvement over no art at all, not the final
                    // state.
                    artUri:
                        Uri.parse('asset:///assets/images/dclm_radio_art.png'),
                  )
                : null,
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
