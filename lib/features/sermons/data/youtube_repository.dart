import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../../../core/database/app_database.dart';
import '../../../core/shared/result.dart';
import '../domain/video_entry.dart';

const _ytBase = 'https://www.googleapis.com/youtube/v3';

/// Ported from cloudflare/youtube-sync/src/youtube.ts's `CATEGORY_KEYWORDS`
/// (PROJECT_MIGRATION_AUDIT.md Phase 3 — deliberately kept identical
/// rather than "improved," per that file's own header comment, so
/// behavior didn't drift when it moved from the Worker to the client).
const _categoryKeywords = <String, List<String>>{
  'Sunday Service': ['sunday', 'communion'],
  'Bible Study': ['bible study'],
  'Revival': ['revival', 'crusade'],
  'GCK': ['gck', 'global crusade'],
  'Impact Academy': ['impact academy', 'leadership training'],
  'Special Messages': ['special message', 'memorial', 'ordination'],
};

String _categorize(String title) {
  final lower = title.toLowerCase();
  for (final entry in _categoryKeywords.entries) {
    if (entry.value.any(lower.contains)) {
      return entry.key;
    }
  }
  return 'Programs';
}

/// Parses YouTube's ISO 8601 duration format (e.g. "PT1H2M10S") — same
/// regex the Worker version used.
int? _parseIso8601Duration(String? iso) {
  if (iso == null) {
    return null;
  }
  final match = RegExp(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?').firstMatch(iso);
  if (match == null) {
    return null;
  }
  final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
  final minutes = int.tryParse(match.group(2) ?? '0') ?? 0;
  final seconds = int.tryParse(match.group(3) ?? '0') ?? 0;
  return hours * 3600 + minutes * 60 + seconds;
}

String _bestThumbnail(Map<String, dynamic>? thumbnails) {
  if (thumbnails == null) {
    return '';
  }
  for (final quality in ['maxres', 'high', 'medium', 'default']) {
    final url = (thumbnails[quality] as Map<String, dynamic>?)?['url'];
    if (url is String && url.isNotEmpty) {
      return url;
    }
  }
  return '';
}

class _ParsedVideo {
  _ParsedVideo({
    required this.videoId,
    required this.title,
    required this.description,
    required this.thumbnailUrl,
    required this.publishedAt,
    required this.channelTitle,
    required this.durationSeconds,
    required this.liveStatus,
    required this.category,
  });

  final String videoId;
  final String title;
  final String description;
  final String thumbnailUrl;
  final DateTime publishedAt;
  final String channelTitle;
  final int? durationSeconds;
  final String liveStatus;
  final String category;
}

_ParsedVideo _parseVideoItem(Map<String, dynamic> item) {
  final snippet = item['snippet'] as Map<String, dynamic>? ?? {};
  final contentDetails = item['contentDetails'] as Map<String, dynamic>?;
  final liveDetails = item['liveStreamingDetails'] as Map<String, dynamic>?;

  var liveStatus = 'none';
  if (liveDetails != null) {
    if (liveDetails['actualStartTime'] != null &&
        liveDetails['actualEndTime'] == null) {
      liveStatus = 'live';
    } else if (liveDetails['scheduledStartTime'] != null &&
        liveDetails['actualStartTime'] == null) {
      liveStatus = 'upcoming';
    }
  }

  final title = snippet['title'] as String? ?? 'Untitled';
  return _ParsedVideo(
    videoId: item['id'] as String,
    title: title,
    description: snippet['description'] as String? ?? '',
    thumbnailUrl:
        _bestThumbnail(snippet['thumbnails'] as Map<String, dynamic>?),
    publishedAt: DateTime.tryParse(snippet['publishedAt'] as String? ?? '') ??
        DateTime.now(),
    channelTitle: snippet['channelTitle'] as String? ?? 'DCLM',
    durationSeconds: liveStatus == 'none'
        ? _parseIso8601Duration(contentDetails?['duration'] as String?)
        : null,
    liveStatus: liveStatus,
    category: _categorize(title),
  );
}

/// Calls the YouTube Data API v3 directly and caches results in Drift
/// (PROJECT_MIGRATION_AUDIT.md Phase 3 — replaces the `youtube-sync`
/// Cloudflare Worker's Firestore-writing proxy pattern). Reads always
/// come from the local cache first (fast, works offline); [refresh]
/// is the only thing that hits the network, called by YoutubeWorker on
/// a timer / app foreground — never on every screen build.
class YoutubeRepository {
  YoutubeRepository([AppDatabase? db])
      : db = db ?? AppDatabaseService.instance.database;
  final AppDatabase db;

  Future<Result<List<VideoEntry>>> getCachedUploads({String? category}) async {
    try {
      final query = db.select(db.youtubeVideos)
        ..orderBy([(t) => OrderingTerm.desc(t.publishedAt)])
        ..limit(50);
      if (category != null) {
        query.where((t) => t.category.equals(category));
      }
      final rows = await query.get();
      return Result.success(rows
          .map((r) => VideoEntry.fromRow(
                videoId: r.videoId,
                title: r.title,
                description: r.description,
                thumbnailUrl: r.thumbnailUrl,
                publishedAt: r.publishedAt,
                channelTitle: r.channelTitle,
                durationSeconds: r.durationSeconds,
                liveStatus: r.liveStatus,
                category: r.category,
              ))
          .toList());
    } catch (e) {
      return Result.failure(AppFailure(
          message: 'Something went wrong loading messages.',
          debugDetail: e.toString()));
    }
  }

  /// Any non-none live/upcoming status with a video id — matches the old
  /// Firestore version's behavior exactly (it didn't filter by status
  /// either, just checked `video_id != null`). Callers that only care
  /// about "is DCLM live right now" (not upcoming) check
  /// `.liveStatus == LiveStatus.live` themselves — see live_screen.dart.
  Stream<VideoEntry?> watchLiveStatus() {
    return (db.select(db.youtubeLiveStatus)..where((t) => t.id.equals(1)))
        .watchSingleOrNull()
        .map((row) {
      if (row == null || row.videoId == null || row.liveStatus == 'none') {
        return null;
      }
      return VideoEntry.fromRow(
        videoId: row.videoId!,
        title: row.title ?? 'DCLM is live now',
        description: '',
        thumbnailUrl: '',
        publishedAt: row.updatedAt,
        channelTitle: 'DCLM',
        liveStatus: row.liveStatus,
      );
    });
  }

  /// One-shot read, for callers (ProgramWorker.getSnapshot) that want a
  /// single current value rather than a live-updating stream.
  Future<VideoEntry?> getLiveStatusOnce() => watchLiveStatus().first;

  Future<http.Response> _get(String url) => http.get(Uri.parse(url));

  Future<Map<String, dynamic>> _fetchJson(String url) async {
    final response = await _get(url);
    if (response.statusCode != 200) {
      throw Exception('YouTube API ${response.statusCode}: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Pulls the channel's latest uploads + live status directly from the
  /// YouTube Data API v3 (AppConfig.youtubeApiKey — a restricted, public
  /// key, per spec §24/§25) and writes them into the local cache. Ported
  /// 1:1 from cloudflare/youtube-sync/src/youtube.ts's `syncYoutube`,
  /// including its uploads-playlist-id-from-channel-id resolution (via
  /// channels.list, not the hardcoded "UC"->"UU" swap trick) and its
  /// separate search.list live-detection call — that call costs ~100
  /// quota units, which is why this only runs on a timer/foreground
  /// trigger (YoutubeWorker), never per screen build.
  Future<Result<void>> refresh() async {
    const apiKey = AppConfig.youtubeApiKey;
    try {
      final channelJson = await _fetchJson(
        '$_ytBase/channels?part=contentDetails&id=${AppConfig.youtubeChannelId}&key=$apiKey',
      );
      final channelItems =
          (channelJson['items'] as List?)?.cast<Map<String, dynamic>>();
      final firstChannel = (channelItems != null && channelItems.isNotEmpty)
          ? channelItems.first
          : null;
      final uploadsPlaylistId = ((firstChannel?['contentDetails']
              as Map<String, dynamic>?)?['relatedPlaylists']
          as Map<String, dynamic>?)?['uploads'] as String?;
      if (uploadsPlaylistId == null) {
        return const Result.failure(
            AppFailure(message: 'Could not resolve DCLM\'s uploads playlist.'));
      }

      final playlistJson = await _fetchJson(
        '$_ytBase/playlistItems?part=snippet&playlistId=$uploadsPlaylistId'
        '&maxResults=${AppConfig.youtubeMaxUploadsPerSync}&key=$apiKey',
      );
      final videoIds = ((playlistJson['items'] as List?) ?? [])
          .cast<Map<String, dynamic>>()
          .map((item) => (item['snippet']
              as Map<String, dynamic>?)?['resourceId'] as Map<String, dynamic>?)
          .map((r) => r?['videoId'] as String?)
          .whereType<String>()
          .join(',');

      if (videoIds.isNotEmpty) {
        final detailsJson = await _fetchJson(
          '$_ytBase/videos?part=snippet,contentDetails,liveStreamingDetails'
          '&id=$videoIds&key=$apiKey',
        );
        final rows = ((detailsJson['items'] as List?) ?? [])
            .cast<Map<String, dynamic>>()
            .map(_parseVideoItem)
            .map((v) => YoutubeVideosCompanion.insert(
                  videoId: v.videoId,
                  title: v.title,
                  description: v.description,
                  thumbnailUrl: v.thumbnailUrl,
                  publishedAt: v.publishedAt,
                  channelTitle: v.channelTitle,
                  durationSeconds: Value(v.durationSeconds),
                  liveStatus: Value(v.liveStatus),
                  category: Value(v.category),
                ))
            .toList();
        await db.batch((b) {
          b.insertAllOnConflictUpdate(db.youtubeVideos, rows);
        });
      }

      // Live/upcoming detection via search.list — see doc comment above
      // on why this is a separate, deliberately infrequent call.
      final searchJson = await _fetchJson(
        '$_ytBase/search?part=snippet&channelId=${AppConfig.youtubeChannelId}'
        '&eventType=live&type=video&key=$apiKey',
      );
      final searchItems =
          (searchJson['items'] as List?)?.cast<Map<String, dynamic>>();
      final firstSearchResult = (searchItems != null && searchItems.isNotEmpty)
          ? searchItems.first
          : null;
      final liveVideoId = (firstSearchResult?['id']
          as Map<String, dynamic>?)?['videoId'] as String?;

      if (liveVideoId != null) {
        final detailsJson = await _fetchJson(
          '$_ytBase/videos?part=snippet,contentDetails,liveStreamingDetails'
          '&id=$liveVideoId&key=$apiKey',
        );
        final items =
            (detailsJson['items'] as List?)?.cast<Map<String, dynamic>>();
        if (items != null && items.isNotEmpty) {
          final v = _parseVideoItem(items.first);
          await db.into(db.youtubeLiveStatus).insertOnConflictUpdate(
                YoutubeLiveStatusCompanion.insert(
                  id: const Value(1),
                  videoId: Value(v.videoId),
                  title: Value(v.title),
                  liveStatus: Value(v.liveStatus),
                  updatedAt: DateTime.now(),
                ),
              );
        }
      } else {
        await db.into(db.youtubeLiveStatus).insertOnConflictUpdate(
              YoutubeLiveStatusCompanion.insert(
                id: const Value(1),
                videoId: const Value(null),
                liveStatus: const Value('none'),
                updatedAt: DateTime.now(),
              ),
            );
      }

      return const Result.success(null);
    } catch (e) {
      return Result.failure(AppFailure(
        message: 'Couldn\'t refresh messages from YouTube.',
        debugDetail: e.toString(),
      ));
    }
  }
}
