/// A single YouTube video (uploaded message or live program) from DCLM's
/// channel, cached locally per PROJECT_MIGRATION_AUDIT.md Phase 3: title,
/// thumbnail, duration, publishedAt, videoId, description, channel,
/// liveStatus — nothing more, so the cache never accidentally holds a raw
/// API response with fields the UI doesn't use.
enum LiveStatus { none, live, upcoming }

class VideoEntry {
  const VideoEntry({
    required this.videoId,
    required this.title,
    required this.description,
    required this.thumbnailUrl,
    required this.publishedAt,
    required this.channelTitle,
    this.durationSeconds,
    this.liveStatus = LiveStatus.none,
    this.category,
  });

  final String videoId;
  final String title;
  final String description;
  final String thumbnailUrl;
  final DateTime publishedAt;
  final String channelTitle;

  /// Null for live/upcoming broadcasts (YouTube doesn't report a fixed
  /// duration for those until they end).
  final int? durationSeconds;
  final LiveStatus liveStatus;

  /// One of the Library categories (Sunday Service, Bible Study, Revival,
  /// GCK, Programs, Impact Academy, Special Messages) — assigned by title
  /// keyword matching in YoutubeRepository, since the YouTube API itself
  /// has no concept of these categories. Null until categorized.
  final String? category;

  String get watchUrl => 'https://www.youtube.com/watch?v=$videoId';

  /// Builds from a Drift `YoutubeVideo` row (was `.fromFirestore` before
  /// Phase 3 — field names are identical, only the source changed).
  factory VideoEntry.fromRow({
    required String videoId,
    required String title,
    required String description,
    required String thumbnailUrl,
    required DateTime publishedAt,
    required String channelTitle,
    int? durationSeconds,
    String liveStatus = 'none',
    String? category,
  }) =>
      VideoEntry(
        videoId: videoId,
        title: title,
        description: description,
        thumbnailUrl: thumbnailUrl,
        publishedAt: publishedAt,
        channelTitle: channelTitle,
        durationSeconds: durationSeconds,
        liveStatus: LiveStatus.values.firstWhere(
          (s) => s.name == liveStatus,
          orElse: () => LiveStatus.none,
        ),
        category: category,
      );
}
