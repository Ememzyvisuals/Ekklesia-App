import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../services/radio_service.dart';
import '../config/app_config.dart';
import '../config/app_theme.dart';

/// A persistent play/pause bar for DCLM Radio, visible across every tab
/// once playback has started — not just on the Live screen.
///
/// This is the "own particular navigation" for radio control that was
/// explicitly asked for: this in-app mini-player is what actually keeps
/// radio control reachable from any tab now — lock-screen controls via
/// `just_audio_background` were tried and removed (see radio_service.dart
/// and pubspec.yaml's comments) after they broke every audio feature in
/// the app on a real device, so this widget carries that responsibility
/// alone rather than as a supplement to lock-screen controls. This
/// widget listens to RadioService directly and only renders anything
/// once a language has actually been selected for playback — silent and
/// takes no space otherwise.
class RadioMiniPlayer extends StatelessWidget {
  const RadioMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: RadioService.instance.stateStream,
      builder: (context, snapshot) {
        final language = RadioService.instance.currentLanguage;
        if (language == null) {
          return const SizedBox.shrink();
        }
        final playing = snapshot.data?.playing ?? false;
        final processingState = snapshot.data?.processingState;
        final loading = processingState == ProcessingState.loading ||
            processingState == ProcessingState.buffering;
        final label = AppConfig.dclmLanguageLabels[language] ?? language;

        return Material(
          color: AppColors.primary,
          child: InkWell(
            onTap: () => context.push('/live'),
            child: SafeArea(
              top: false,
              bottom: false,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.radio_rounded,
                        color: Colors.white, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: StreamBuilder<DclmNowPlaying?>(
                        stream: RadioService.instance.nowPlayingStream,
                        builder: (context, nowPlayingSnapshot) {
                          final nowPlaying = nowPlayingSnapshot.data;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'DCLM Radio: $label',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (nowPlaying != null)
                                Text(
                                  nowPlaying.title,
                                  style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.7),
                                      fontSize: 11),
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    IconButton(
                      color: Colors.white,
                      icon: loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Icon(playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded),
                      onPressed: loading
                          ? null
                          : () {
                              if (playing) {
                                RadioService.instance.pause();
                              } else {
                                RadioService.instance.resume();
                              }
                            },
                    ),
                    IconButton(
                      color: Colors.white,
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () => RadioService.instance.stop(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
