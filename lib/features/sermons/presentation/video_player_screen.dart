import 'package:flutter/material.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:intl/intl.dart';

import '../../../core/config/app_theme.dart';
import '../../../core/shared/result.dart';
import '../../bookmarks/presentation/bookmark_button.dart';
import '../../bookmarks/domain/bookmark_item.dart';
import '../data/message_overview_service.dart';
import '../domain/video_entry.dart';

/// Watch screen for a single message/program.
///
/// [YoutubePlayerBuilder] (from youtube_player_flutter) handles the
/// portrait <-> landscape / fullscreen transition natively — rotating the
/// device or tapping fullscreen expands the player and hides the
/// description/overview below it, rather than this screen reimplementing
/// orientation handling itself.
class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({super.key, required this.video});
  final VideoEntry video;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late final YoutubePlayerController _controller;
  final _overviewService = MessageOverviewService();
  Result<MessageOverview>? _overview;

  @override
  void initState() {
    super.initState();
    _controller = YoutubePlayerController(
      initialVideoId: widget.video.videoId,
      flags: YoutubePlayerFlags(
        autoPlay: false,
        isLive: widget.video.liveStatus == LiveStatus.live,
      ),
    );
    _loadOverview();
  }

  Future<void> _loadOverview() async {
    setState(() => _overview = const Result.loading());
    final result = await _overviewService.getOverview(
      videoId: widget.video.videoId,
      title: widget.video.title,
      description: widget.video.description,
    );
    if (mounted) {
      setState(() => _overview = result);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return YoutubePlayerBuilder(
      player: YoutubePlayer(
          controller: _controller, showVideoProgressIndicator: true),
      builder: (context, player) {
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.video.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              BookmarkButton(
                type: BookmarkType.sermon,
                refId: widget.video.videoId,
                title: widget.video.title,
                subtitle: widget.video.channelTitle,
              ),
            ],
          ),
          body: ListView(
            children: [
              player,
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (widget.video.liveStatus == LiveStatus.live)
                          const _LiveBadge(),
                        if (widget.video.category != null) ...[
                          const SizedBox(width: 8),
                          Chip(
                              label: Text(widget.video.category!),
                              backgroundColor: AppColors.secondary),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(widget.video.title,
                        style: AppTypography.titleLarge(
                            color: AppTheme.textPrimary(context))),
                    const SizedBox(height: 6),
                    Text(
                      DateFormat.yMMMd().format(widget.video.publishedAt),
                      style: AppTypography.bodySmall(
                          color: AppTheme.textSecondary(context)),
                    ),
                    const SizedBox(height: 24),
                    _OverviewSection(result: _overview, onRetry: _loadOverview),
                    if (widget.video.description.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Text('Description',
                          style: AppTypography.titleSmall(
                              color: AppTheme.textPrimary(context))),
                      const SizedBox(height: 8),
                      Text(widget.video.description,
                          style: AppTypography.bodyMedium(
                              color: AppTheme.textSecondary(context))),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
          color: AppColors.error, borderRadius: BorderRadius.circular(6)),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: Colors.white),
          SizedBox(width: 6),
          Text('LIVE',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 12)),
        ],
      ),
    );
  }
}

class _OverviewSection extends StatelessWidget {
  const _OverviewSection({required this.result, required this.onRetry});
  final Result<MessageOverview>? result;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: AppTheme.surface(context),
          borderRadius: BorderRadius.circular(20)),
      child: switch (result) {
        null || ResultLoading() => const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator()),
          ),
        ResultFailure(failure: final f) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(f.message,
                  style: AppTypography.bodyMedium(
                      color: AppTheme.textSecondary(context))),
              const SizedBox(height: 8),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ResultSuccess(data: final overview) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_awesome,
                      size: 18, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Text('AI overview',
                      style: AppTypography.titleSmall(
                          color: AppTheme.textPrimary(context))),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Based on the title and description — not a transcript of the message.',
                style: AppTypography.caption(
                    color: AppTheme.textSecondary(context)),
              ),
              const SizedBox(height: 12),
              Text('Topic',
                  style: AppTypography.bodySmall(
                      color: AppTheme.textSecondary(context))),
              Text(overview.topic,
                  style: AppTypography.bodyLarge(
                      color: AppTheme.textPrimary(context))),
              const SizedBox(height: 12),
              Text(overview.summary,
                  style: AppTypography.bodyMedium(
                      color: AppTheme.textPrimary(context))),
              if (overview.pointsToConsider.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Points to consider',
                    style: AppTypography.bodySmall(
                        color: AppTheme.textSecondary(context))),
                const SizedBox(height: 6),
                ...overview.pointsToConsider.map((p) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('•  '),
                          Expanded(
                              child: Text(p,
                                  style: AppTypography.bodyMedium(
                                      color: AppTheme.textPrimary(context)))),
                        ],
                      ),
                    )),
              ],
            ],
          ),
      },
    );
  }
}
