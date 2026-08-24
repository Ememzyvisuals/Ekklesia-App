import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart'
    hide PlayerState;

import '../../../core/services/radio_service.dart';
import '../../../core/config/app_theme.dart';
import '../../../core/config/app_config.dart';
import '../../sermons/data/youtube_repository.dart';
import '../../sermons/domain/video_entry.dart';
import '../../sermons/presentation/sermon_library_screen.dart';
import '../../sermons/data/youtube_worker.dart';

/// Real radio streaming screen — plays DCLM's direct Icecast/Airtime
/// mounts with proper lock-screen controls, plus shows the YouTube live
/// stream when Deeper Christian Life Ministry (DCLM) is live.
///
/// Live status comes from a local Drift stream (YoutubeRepository.
/// watchLiveStatus), populated by YoutubeWorker's periodic refresh —
/// not a fresh YouTube API call every time this screen opens. A live
/// search.list call costs real quota (~100 units out of 10,000/day); polling
/// it on every screen visit would burn through that fast with any real
/// user base, which is exactly the "avoid battery/quota drain" rule the
/// addendum's worker section calls for.
///
/// This is the feature meant to fix what the official DCLM app doesn't:
/// audio that keeps playing when the screen locks.
class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  String _selectedLanguage = 'english';
  bool _isPlaying = false;
  bool _loading = false;
  String? _error;
  // Same pattern as bible_screen.dart / ai_assistant_screen.dart's
  // _errorDetail — friendly message by default, real exception text one
  // tap away behind "Details."
  String? _errorDetail;

  final _youtubeRepository = YoutubeRepository();
  YoutubePlayerController? _ytController;
  String? _controllerVideoId;

  Future<void> _toggleRadio() async {
    setState(() {
      _loading = true;
      _error = null;
      _errorDetail = null;
    });
    try {
      if (_isPlaying &&
          RadioService.instance.currentLanguage == _selectedLanguage) {
        await RadioService.instance.pause();
        setState(() => _isPlaying = false);
      } else {
        await RadioService.instance.playLanguage(_selectedLanguage);
        setState(() => _isPlaying = true);
      }
    } catch (e) {
      // Was `_error = e.toString()` — same raw-exception-in-the-UI
      // problem as the AI Assistant screen; see that fix's comment for
      // why this matters on a real, often-offline device.
      final message = e.toString().toLowerCase();
      if (message.contains('timeoutexception') ||
          message.contains('socketexception') ||
          message.contains('failed host lookup') ||
          message.contains('network is unreachable')) {
        setState(() =>
            _error = "You're offline. The radio needs an internet connection.");
      } else {
        setState(
            () => _error = "Couldn't start the stream. Try again in a moment.");
      }
      setState(() => _errorDetail = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _ytController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live'),
        // Explicit "back to Home" — this screen can be reached from
        // any tab (the radio mini-player's tap target works from
        // anywhere, see radio_mini_player.dart), so a plain back arrow
        // relying on Navigator.pop() would land wherever the person
        // happened to be, not necessarily Home. context.go (not push)
        // guarantees landing on Home specifically, matching the
        // explicit request.
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to Home',
          onPressed: () => context.go('/home'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- YouTube live card ----
          StreamBuilder<VideoEntry?>(
            stream: _youtubeRepository.watchLiveStatus(),
            builder: (context, snapshot) {
              final live = snapshot.data;
              if (live == null) {
                // YoutubeWorker.lastError is the fix for a real, confirmed
                // bug: this empty state used to show unconditionally even
                // when the last sync had actually failed (bad API key,
                // quota, no internet) — the failure was computed
                // correctly but discarded, never reaching the UI at all.
                // Now the real reason shows here if there is one.
                final syncError = YoutubeWorker.lastError;
                final syncErrorDetail = YoutubeWorker.lastErrorDetail;
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.secondary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                          syncError != null
                              ? Icons.error_outline
                              : CupertinoIcons.video_camera,
                          color: AppTheme.textSecondary(context)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(syncError != null
                                ? "Couldn't check for a live stream: $syncError"
                                : 'No live YouTube stream right now.'),
                            if (syncErrorDetail != null)
                              InkWell(
                                onTap: () => showDialog<void>(
                                  context: context,
                                  builder: (dialogContext) => AlertDialog(
                                    title: const Text('Error details'),
                                    content: SingleChildScrollView(
                                      child: SelectableText(syncErrorDetail),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(dialogContext).pop(),
                                        child: const Text('Close'),
                                      ),
                                    ],
                                  ),
                                ),
                                child: const Padding(
                                  padding: EdgeInsets.only(top: 4),
                                  child: Text('Details',
                                      style: TextStyle(
                                          decoration:
                                              TextDecoration.underline,
                                          fontSize: 12)),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }

              if (_controllerVideoId != live.videoId) {
                _ytController?.dispose();
                _ytController = YoutubePlayerController(
                  initialVideoId: live.videoId,
                  flags:
                      const YoutubePlayerFlags(autoPlay: false, isLive: true),
                );
                _controllerVideoId = live.videoId;
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Live Now',
                      style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  YoutubePlayer(controller: _ytController!),
                  const SizedBox(height: 8),
                  Text(live.title,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 24),
                ],
              );
            },
          ),

          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SermonLibraryScreen()),
            ),
            icon: const Icon(CupertinoIcons.play_rectangle),
            label: const Text('Browse Sermon Library'),
          ),

          const SizedBox(height: 24),
          Text('DCLM Radio', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),

          DropdownButtonFormField<String>(
            initialValue: _selectedLanguage,
            decoration: const InputDecoration(
              labelText: 'Language',
              border: OutlineInputBorder(),
            ),
            // All 18 verified DCLM language streams, not just the
            // original 4 — dclmExtraStreams' 14 additional languages
            // were already real/verified in AppConfig, just never
            // exposed here. Grouped with a non-selectable divider label
            // so 18 flat items don't read as an undifferentiated wall —
            // matches how the official site itself separates "main"
            // languages from the rest.
            items: [
              ...AppConfig.dclmStreams.keys.map(
                  (k) => DropdownMenuItem(value: k, child: Text(_label(k)))),
              const DropdownMenuItem(
                enabled: false,
                child: Divider(),
              ),
              ...AppConfig.dclmExtraStreams.keys.map(
                  (k) => DropdownMenuItem(value: k, child: Text(_label(k)))),
            ],
            onChanged: (v) async {
              if (v == null) return;
              setState(() => _selectedLanguage = v);
              if (_isPlaying) {
                await RadioService.instance.playLanguage(_selectedLanguage);
              }
            },
          ),
          const SizedBox(height: 16),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                  if (_errorDetail != null)
                    InkWell(
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Error details'),
                          content: SingleChildScrollView(
                            child: SelectableText(_errorDetail ?? ''),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text('Details',
                            style: TextStyle(
                                color: Colors.red,
                                decoration: TextDecoration.underline,
                                fontSize: 12)),
                      ),
                    ),
                ],
              ),
            ),

          // Premium player card: a deep, subtly-graded green (not a flat
          // fill) with soft depth, matching the rest of the app's rounded
          // premium-card language (20px radius) rather than the sharper
          // 16px flat-gold card this replaced.
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.primary,
                  Color.lerp(AppColors.primary, Colors.black, 0.3)!
                ],
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.35),
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: Text(
                    _isPlaying
                        ? 'Now Playing: ${_label(_selectedLanguage)}'
                        : 'Tap to Play',
                    key: ValueKey(_isPlaying),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                StreamBuilder<PlayerState>(
                  stream: RadioService.instance.stateStream,
                  builder: (context, snapshot) {
                    final buffering = snapshot.data?.processingState ==
                        ProcessingState.buffering;
                    final showSpinner = buffering || _loading;
                    // A tasteful, restrained tap animation — scales down
                    // slightly on press, back to full size on release —
                    // not a bounce or spin, matching the "no over-animate"
                    // direction elsewhere in the app.
                    return _PremiumPlayButton(
                      onTap: showSpinner ? null : _toggleRadio,
                      isPlaying: _isPlaying,
                      showSpinner: showSpinner,
                    );
                  },
                ),
                const SizedBox(height: 12),
                const Text(
                  'Stays playing even when your screen locks',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  child: _isPlaying
                      ? StreamBuilder<DclmNowPlaying?>(
                          stream: RadioService.instance.nowPlayingStream,
                          builder: (context, snapshot) {
                            final info = snapshot.data;
                            if (info == null) return const SizedBox.shrink();
                            return AnimatedOpacity(
                              duration: const Duration(milliseconds: 250),
                              opacity: 1,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: Column(
                                  children: [
                                    const Divider(
                                        color: Colors.white24, height: 1),
                                    const SizedBox(height: 12),
                                    Text(
                                      '${info.title} · ${info.artist}',
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 13),
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        const Icon(CupertinoIcons.person_2_fill,
                                            size: 13, color: Colors.white70),
                                        const SizedBox(width: 4),
                                        Text(
                                          '${info.listeners} listening now',
                                          style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _label(String key) => AppConfig.dclmLanguageLabels[key] ?? key;
}

/// A restrained, iOS-style circular play/pause control: a filled white
/// disc (not a bare oversized icon like the previous version) with a
/// subtle scale-down on press and a smooth crossfade between play/pause/
/// spinner states — deliberately not a bounce, spin, or pulse, matching
/// this app's "smooth, not over-animated" direction elsewhere.
class _PremiumPlayButton extends StatefulWidget {
  const _PremiumPlayButton(
      {required this.onTap,
      required this.isPlaying,
      required this.showSpinner});
  final VoidCallback? onTap;
  final bool isPlaying;
  final bool showSpinner;

  @override
  State<_PremiumPlayButton> createState() => _PremiumPlayButtonState();
}

class _PremiumPlayButtonState extends State<_PremiumPlayButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown:
          widget.onTap == null ? null : (_) => setState(() => _pressed = true),
      onTapUp:
          widget.onTap == null ? null : (_) => setState(() => _pressed = false),
      onTapCancel:
          widget.onTap == null ? null : () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 16,
                  offset: const Offset(0, 6)),
            ],
          ),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: widget.showSpinner
                  ? const SizedBox(
                      key: ValueKey('spinner'),
                      height: 28,
                      width: 28,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: AppColors.primary),
                    )
                  : Icon(
                      widget.isPlaying
                          ? CupertinoIcons.pause_solid
                          : CupertinoIcons.play_fill,
                      key: ValueKey(widget.isPlaying),
                      color: AppColors.primary,
                      size: 32,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
