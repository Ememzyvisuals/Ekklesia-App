import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_theme.dart';
import '../../../core/services/download_worker.dart';
import '../../../core/shared/result.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../ai/data/conversation_repository.dart';
import '../../bible/data/bible_providers.dart';
import '../../bookmarks/data/bookmark_providers.dart';
import '../../sermons/data/youtube_repository.dart';
import '../../sermons/domain/video_entry.dart';
import '../../sermons/presentation/video_player_screen.dart';

/// Global search — federates across every locally-available source
/// rather than one hand-rolled full-text index, per the spec's "Search:
/// Bible, Programs, Messages, Downloads, Bookmarks, AI Conversations,
/// Settings" list:
///
/// - Sermons/Programs: substring match over the already-synced
///   `youtube_videos` cache (YoutubeRepository.getCachedUploads) — no
///   extra API calls, searches exactly what's already local.
/// - Bookmarks: substring match over the signed-in user's bookmarks.
/// - Downloads: substring match over DownloadWorker's task list.
/// - AI Conversations: reuses ConversationRepository.search, which
///   already existed and already does this properly.
/// - Bible: real offline full-text search via BibleRepository.search,
///   over whichever Bible language is currently selected
///   (bibleLanguageProvider). If that language hasn't been imported yet,
///   the query throws and this source is skipped silently — same
///   fail-soft pattern as the other sources.
/// - Settings: a small static, hardcoded list of setting labels — this
///   one genuinely doesn't need a repository.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

enum _SearchSourceType {
  sermon,
  bookmark,
  download,
  aiConversation,
  settingsShortcut,
  bible
}

class _SearchResult {
  _SearchResult(
      {required this.type,
      required this.title,
      required this.subtitle,
      this.payload});
  final _SearchSourceType type;
  final String title;
  final String subtitle;
  final Object? payload;
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  List<_SearchResult> _results = [];

  static const _settingsShortcuts = [
    ('Language & Voice', '/settings'),
    ('Appearance / Theme', '/settings'),
    ('Downloads', '/downloads'),
    ('Notifications', '/notifications'),
    ('Sign Out', '/settings'),
  ];

  void _onChanged(String query) {
    _debounce?.cancel();
    _debounce =
        Timer(const Duration(milliseconds: 350), () => _search(query.trim()));
  }

  Future<void> _search(String query) async {
    if (query.isEmpty) {
      setState(() => _results = []);
      return;
    }
    setState(() => _loading = true);

    final needle = query.toLowerCase();
    final results = <_SearchResult>[];

    // Sermons/Programs
    final sermonsResult = await YoutubeRepository().getCachedUploads();
    if (sermonsResult case ResultSuccess(data: final videos)) {
      for (final v in videos) {
        if (v.title.toLowerCase().contains(needle) ||
            v.description.toLowerCase().contains(needle)) {
          results.add(_SearchResult(
              type: _SearchSourceType.sermon,
              title: v.title,
              subtitle: v.channelTitle,
              payload: v));
        }
      }
    }

    // Bookmarks — no more sign-in gate; local-first bookmarks aren't tied
    // to a Firebase uid anymore (PROJECT_MIGRATION_AUDIT.md Phase 1).
    try {
      final bookmarks = await ref
          .read(bookmarkRepositoryProvider)
          .watchAll()
          .first
          .timeout(const Duration(seconds: 5));
      for (final b in bookmarks) {
        if (b.title.toLowerCase().contains(needle) ||
            b.subtitle.toLowerCase().contains(needle)) {
          results.add(_SearchResult(
              type: _SearchSourceType.bookmark,
              title: b.title,
              subtitle: b.subtitle,
              payload: b));
        }
      }
    } catch (_) {
      // Offline with nothing cached yet — skip this source silently,
      // other sources still return what they can.
    }

    // AI Conversations — Drift-backed now (PROJECT_MIGRATION_AUDIT.md
    // Phase 4), no uid/sign-in gate needed anymore.
    try {
      final messages = await ConversationRepository.instance.search(query);
      for (final m in messages) {
        results.add(_SearchResult(
          type: _SearchSourceType.aiConversation,
          title:
              m.text.length > 80 ? '${m.text.substring(0, 77)}...' : m.text,
          subtitle: m.role == 'user' ? 'You asked' : 'AI replied',
          payload: m,
        ));
      }
    } catch (_) {}

    // Bible (offline full-text search over the currently selected
    // Bible language — skipped silently if that language isn't imported)
    try {
      final bibleLanguage = ref.read(bibleLanguageProvider);
      final repo = ref.read(bibleRepositoryProvider);
      final verses = await repo.search(bibleLanguage, query, limit: 15);
      for (final v in verses) {
        results.add(_SearchResult(
          type: _SearchSourceType.bible,
          title: '${v.bookCode} ${v.chapter}:${v.number}',
          subtitle: v.text ?? '',
          payload: v,
        ));
      }
    } catch (_) {}

    // Downloads
    try {
      final downloads = await DownloadWorker.instance.getAll();
      for (final d in downloads) {
        if (d.title.toLowerCase().contains(needle)) {
          results.add(_SearchResult(
              type: _SearchSourceType.download,
              title: d.title,
              subtitle: 'Download',
              payload: d));
        }
      }
    } catch (_) {}

    // Settings shortcuts
    for (final (label, route) in _settingsShortcuts) {
      if (label.toLowerCase().contains(needle)) {
        results.add(_SearchResult(
            type: _SearchSourceType.settingsShortcut,
            title: label,
            subtitle: 'Settings',
            payload: route));
      }
    }

    if (mounted)
      setState(() {
        _results = results;
        _loading = false;
      });
  }

  void _open(_SearchResult result) {
    switch (result.type) {
      case _SearchSourceType.sermon:
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                VideoPlayerScreen(video: result.payload as VideoEntry)));
        break;
      case _SearchSourceType.bookmark:
        context.push('/bookmarks');
        break;
      case _SearchSourceType.download:
        context.push('/downloads');
        break;
      case _SearchSourceType.aiConversation:
        context.push('/ai');
        break;
      case _SearchSourceType.settingsShortcut:
        context.push(result.payload as String);
        break;
      case _SearchSourceType.bible:
        context.push('/bible');
        break;
    }
  }

  IconData _iconFor(_SearchSourceType type) {
    switch (type) {
      case _SearchSourceType.sermon:
        return Icons.play_circle_outline;
      case _SearchSourceType.bookmark:
        return Icons.bookmark_outline;
      case _SearchSourceType.download:
        return Icons.download_outlined;
      case _SearchSourceType.aiConversation:
        return Icons.smart_toy_outlined;
      case _SearchSourceType.settingsShortcut:
        return Icons.settings_outlined;
      case _SearchSourceType.bible:
        return Icons.menu_book_outlined;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: AppLocalizations.of(context).searchHint,
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _controller.text.trim().isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      AppLocalizations.of(context).searchEmptyPrompt,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                )
              : _results.isEmpty
                  ? Center(
                      child: Text(AppLocalizations.of(context).searchNoResults,
                          style:
                              const TextStyle(color: AppColors.textSecondary)))
                  : ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final r = _results[index];
                        return ListTile(
                          leading:
                              Icon(_iconFor(r.type), color: AppColors.accent),
                          title: Text(r.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(r.subtitle,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => _open(r),
                        );
                      },
                    ),
    );
  }
}
