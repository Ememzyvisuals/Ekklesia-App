import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../core/config/app_theme.dart';
import '../../../core/shared/result.dart';
import '../data/youtube_repository.dart';
import '../domain/video_entry.dart';
import 'video_player_screen.dart';

const List<String> _categories = [
  'All',
  'Sunday Service',
  'Bible Study',
  'Revival',
  'GCK',
  'Impact Academy',
  'Special Messages',
  'Programs',
];

class SermonLibraryScreen extends StatefulWidget {
  const SermonLibraryScreen({super.key});

  @override
  State<SermonLibraryScreen> createState() => _SermonLibraryScreenState();
}

class _SermonLibraryScreenState extends State<SermonLibraryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _repository = YoutubeRepository();
  Result<List<VideoEntry>> _result = const Result.loading();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _categories.length, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        _load();
      }
    });
    _load();
  }

  Future<void> _load() async {
    setState(() => _result = const Result.loading());
    final category = _categories[_tabController.index];
    final result = await _repository.getCachedUploads(
        category: category == 'All' ? null : category);
    if (mounted) {
      setState(() => _result = result);
    }
  }

  Future<void> _pullToRefresh() async {
    await _repository
        .refresh(); // real API pull, not just re-reading the same cache
    await _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sermon Library'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: _categories.map((c) => Tab(text: c)).toList(),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _pullToRefresh,
        child: switch (_result) {
          ResultLoading() => const Center(child: CircularProgressIndicator()),
          ResultFailure(failure: final f) =>
            _ErrorState(message: f.message, onRetry: _load),
          ResultSuccess(data: final videos) =>
            videos.isEmpty ? const _EmptyState() : _VideoList(videos: videos),
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        Icon(Icons.church_outlined,
            size: 48, color: AppTheme.textSecondary(context)),
        const SizedBox(height: 16),
        Center(
          child: Text(
            'No messages here yet — pull down to check for new uploads.',
            textAlign: TextAlign.center,
            style: AppTypography.bodyMedium(
                color: AppTheme.textSecondary(context)),
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        const Icon(Icons.wifi_off, size: 48, color: AppColors.error),
        const SizedBox(height: 16),
        Center(child: Text(message, textAlign: TextAlign.center)),
        const SizedBox(height: 16),
        Center(
            child:
                ElevatedButton(onPressed: onRetry, child: const Text('Retry'))),
      ],
    );
  }
}

/// Landscape (16:9 "front view") thumbnail cards, per the standard sermon-
/// library browsing pattern — a single wide thumbnail with title/metadata
/// below, rather than a portrait poster crop that hides most of the frame.
class _VideoList extends StatelessWidget {
  const _VideoList({required this.videos});
  final List<VideoEntry> videos;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: videos.length,
      separatorBuilder: (_, __) => const SizedBox(height: 16),
      itemBuilder: (context, i) {
        final video = videos[i];
        return GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => VideoPlayerScreen(video: video)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedNetworkImage(
                        imageUrl: video.thumbnailUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(color: AppColors.secondary),
                        errorWidget: (_, __, ___) =>
                            Container(color: AppColors.secondary),
                      ),
                      if (video.liveStatus == LiveStatus.live)
                        Positioned(
                            top: 8,
                            left: 8,
                            child: _tag('LIVE', AppColors.error)),
                      if (video.durationSeconds != null)
                        Positioned(
                            bottom: 8,
                            right: 8,
                            child: _tag(_formatDuration(video.durationSeconds!),
                                Colors.black87)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(video.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.titleSmall(
                      color: AppTheme.textPrimary(context))),
              const SizedBox(height: 2),
              Text(video.category ?? 'Programs',
                  style: AppTypography.bodySmall(
                      color: AppTheme.textSecondary(context))),
            ],
          ),
        );
      },
    );
  }

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration:
            BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600)),
      );

  String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
