import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/groq_service.dart';
import '../../../core/shared/result.dart';

/// The AI overview shown under a video. Built from the video's title +
/// YouTube description only — NOT a transcript of what was actually
/// preached. YouTube's caption-download endpoints require the channel
/// owner's authorization for most videos, and the addendum explicitly
/// forbids scraping as a substitute. So this is honestly scoped: a
/// well-reasoned overview of what the message is *about*, based on its
/// stated title/description, not a summary of its spoken content. The UI
/// must label it that way rather than imply it's heard the sermon.
class MessageOverview {
  const MessageOverview(
      {required this.topic,
      required this.summary,
      required this.pointsToConsider});
  final String topic;
  final String summary;
  final List<String> pointsToConsider;

  factory MessageOverview.fromJson(Map<String, dynamic> json) =>
      MessageOverview(
        topic: json['topic'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        pointsToConsider:
            (json['points_to_consider'] as List<dynamic>? ?? []).cast<String>(),
      );

  Map<String, dynamic> toJson() => {
        'topic': topic,
        'summary': summary,
        'points_to_consider': pointsToConsider,
      };
}

class MessageOverviewService {
  MessageOverviewService({AppDatabase? db})
      : _db = db ?? AppDatabaseService.instance.database;

  final AppDatabase _db;

  /// PROJECT_MIGRATION_AUDIT.md Phase 4 fix: this used to read/write the
  /// Firestore `youtube_videos` collection directly — orphaned since
  /// Phase 3 moved YouTube data to Drift (`YoutubeVideos`) and nothing
  /// else touches that Firestore collection anymore. Found while
  /// auditing for exactly this kind of leftover cross-reference. Now
  /// caches onto the same Drift row YoutubeRepository already
  /// maintains, via its new `aiOverviewJson` column, instead of a
  /// separate, disconnected store.
  Future<Result<MessageOverview>> getOverview({
    required String videoId,
    required String title,
    required String description,
  }) async {
    try {
      final row = await (_db.select(_db.youtubeVideos)
            ..where((t) => t.videoId.equals(videoId)))
          .getSingleOrNull();

      if (row?.aiOverviewJson != null) {
        return Result.success(MessageOverview.fromJson(
            jsonDecode(row!.aiOverviewJson!) as Map<String, dynamic>));
      }

      final overview = await _generate(title: title, description: description);

      // Only update if the video is actually cached locally (it always
      // should be by the time this is called from a screen showing the
      // video) — if not, still return the generated overview, just skip
      // caching it rather than throwing.
      if (row != null) {
        await (_db.update(_db.youtubeVideos)
              ..where((t) => t.videoId.equals(videoId)))
            .write(YoutubeVideosCompanion(
          aiOverviewJson: Value(jsonEncode(overview.toJson())),
        ));
      }

      return Result.success(overview);
    } catch (e) {
      return Result.failure(AppFailure(
        message: 'Couldn\'t generate an overview for this message right now.',
        debugDetail: e.toString(),
      ));
    }
  }

  Future<MessageOverview> _generate(
      {required String title, required String description}) async {
    final prompt = '''
You are helping a Christian app show a short, grounded overview of a sermon
before someone watches it. You only have the title and description below —
you have NOT heard the sermon, so never invent specific claims, verses, or
quotes as if you had. Base everything strictly on what these two fields
actually say, filling gaps with reasonable, clearly general framing only.

Title: $title
Description: ${description.isEmpty ? '(none provided)' : description}

Respond with ONLY this JSON object, no other text, no markdown fences:
{"topic": "one short phrase naming the likely subject", "summary": "2-3 sentence plain-language overview of what this message is likely about, in your own words", "points_to_consider": ["3-4 short reflection prompts a listener could keep in mind while watching, general enough to be honest given you have not heard the message"]}
''';

    final response = await GroqService.instance.chat([
      const GroqMessage(
          role: 'system',
          content: 'You output strictly valid JSON and nothing else.'),
      GroqMessage(role: 'user', content: prompt),
    ]);

    final cleaned =
        response.replaceAll('```json', '').replaceAll('```', '').trim();
    final json = jsonDecode(cleaned) as Map<String, dynamic>;
    return MessageOverview.fromJson(json);
  }
}
