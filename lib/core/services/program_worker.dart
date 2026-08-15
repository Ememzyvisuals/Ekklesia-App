import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../config/app_config.dart';
import '../shared/result.dart';
import '../../features/sermons/data/youtube_repository.dart';
import '../../features/sermons/domain/video_entry.dart';

/// A single row in `assets/data/programs.json` — a recurring church
/// schedule rule (e.g. "Sunday Service, Sundays, 09:00"), NOT a specific
/// dated event. Per the spec's "never require an administrator to pin
/// programs" rule, these rules exist so ProgramWorker can compute
/// today's schedule automatically instead of someone manually creating a
/// dated entry every week.
///
/// Bundled as a local JSON asset (no admin panel per spec — "Do NOT
/// build an in-app admin panel"; offline-first — no backend to hold a
/// live collection). Updating the schedule means editing that file and
/// shipping a new build.
class ProgramRule {
  const ProgramRule({
    required this.title,
    required this.dayOfWeek, // 1 = Monday .. 7 = Sunday (DateTime.weekday)
    required this.startHour,
    required this.startMinute,
    required this.category,
  });

  final String title;
  final int dayOfWeek;
  final int startHour;
  final int startMinute;
  final String category;

  factory ProgramRule.fromJson(Map<String, dynamic> data) => ProgramRule(
        title: data['title'] as String? ?? 'Program',
        dayOfWeek: data['day_of_week'] as int? ?? 7,
        startHour: data['start_hour'] as int? ?? 9,
        startMinute: data['start_minute'] as int? ?? 0,
        category: data['category'] as String? ?? 'Programs',
      );
}

/// Combined view the Home screen needs: what's live right now, what's
/// coming up, what was recently uploaded, and today's schedule — computed
/// automatically from YouTube state + the `programs` schedule rules, never
/// from a manually-pinned "featured" flag.
class ProgramSnapshot {
  const ProgramSnapshot({
    this.live,
    this.upcoming,
    this.recent,
    required this.todaysSchedule,
  });

  final VideoEntry? live;
  final VideoEntry? upcoming;
  final VideoEntry? recent;
  final List<ProgramRule> todaysSchedule;

  /// Featured = live if there is one, else the next scheduled/upcoming
  /// item, else the most recent upload. Never a manually-set flag.
  VideoEntry? get featured => live ?? upcoming ?? recent;
}

class ProgramWorker {
  ProgramWorker._internal();
  static final ProgramWorker instance = ProgramWorker._internal();

  final _youtubeRepository = YoutubeRepository();

  // Parsed once and cached in memory — this is a small, static, bundled
  // file, not something that changes between app launches.
  List<ProgramRule>? _rulesCache;

  Future<ProgramSnapshot> getSnapshot() async {
    VideoEntry? live;
    VideoEntry? upcoming;
    VideoEntry? recent;

    // PROJECT_MIGRATION_AUDIT.md Phase 3: this used to read the
    // `config/youtube_live_status` Firestore doc directly. YoutubeRepository
    // is Drift-backed now (see youtube_repository.dart) — getLiveStatusOnce()
    // is the one-shot equivalent read.
    final liveEntry = await _youtubeRepository.getLiveStatusOnce();
    if (liveEntry != null) {
      if (liveEntry.liveStatus == LiveStatus.live) {
        live = liveEntry;
      } else if (liveEntry.liveStatus == LiveStatus.upcoming) {
        upcoming = liveEntry;
      }
    }

    final cachedResult = await _youtubeRepository.getCachedUploads();
    if (cachedResult is ResultSuccess<List<VideoEntry>> &&
        cachedResult.data.isNotEmpty) {
      recent = cachedResult.data.first;
    }

    final todaysSchedule = await _todaysScheduleRules();

    return ProgramSnapshot(
      live: live,
      upcoming: upcoming,
      recent: recent,
      todaysSchedule: todaysSchedule,
    );
  }

  Future<List<ProgramRule>> _allRules() async {
    final cached = _rulesCache;
    if (cached != null) return cached;
    try {
      final raw = await rootBundle.loadString(AppConfig.programsAssetPath);
      final decoded = jsonDecode(raw) as List<dynamic>;
      final rules = decoded
          .map((e) => ProgramRule.fromJson(e as Map<String, dynamic>))
          .toList();
      _rulesCache = rules;
      return rules;
    } catch (_) {
      // Missing/malformed asset — fail open with an empty schedule rather
      // than crashing the Home screen.
      return const [];
    }
  }

  Future<List<ProgramRule>> _todaysScheduleRules() async {
    final weekday = DateTime.now().weekday;
    final rules =
        (await _allRules()).where((r) => r.dayOfWeek == weekday).toList();
    rules.sort((a, b) => (a.startHour * 60 + a.startMinute)
        .compareTo(b.startHour * 60 + b.startMinute));
    return rules;
  }
}
