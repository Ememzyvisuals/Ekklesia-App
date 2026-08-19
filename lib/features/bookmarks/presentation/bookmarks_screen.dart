import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/config/app_theme.dart';
import '../../../core/shared/result.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../data/bookmark_providers.dart';
import '../domain/bookmark_item.dart';
import '../../bible/presentation/bible_screen.dart';
import '../../sermons/data/youtube_repository.dart';
import '../../sermons/domain/video_entry.dart';
import '../../sermons/presentation/video_player_screen.dart';

/// Bookmarks list — Bible references, sermons, and AI conversations in
/// one place, grouped by type. Tapping a sermon bookmark re-fetches its
/// VideoEntry from the youtube_videos cache (bookmarks only store the
/// video id, not a full copy, so if a video was ever removed from the
/// channel the bookmark surfaces that instead of opening a broken
/// player). Tapping a Bible bookmark reopens the Bible screen (currently
/// single-reference, not deep-linked to a specific passage yet — see
/// the note on BibleScreen needing a constructor param for that).
class BookmarksScreen extends ConsumerWidget {
  const BookmarksScreen({super.key});

  IconData _iconFor(BookmarkType type) {
    switch (type) {
      case BookmarkType.bible:
        return Icons.menu_book;
      case BookmarkType.sermon:
        return Icons.play_circle_outline;
      case BookmarkType.aiConversation:
        return Icons.smart_toy_outlined;
    }
  }

  Future<void> _open(BuildContext context, BookmarkItem item) async {
    switch (item.type) {
      case BookmarkType.bible:
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => BibleScreen(
            initialReference: item.refId,
            initialLanguage: item.language,
          ),
        ));
        break;
      case BookmarkType.sermon:
        final result = await YoutubeRepository().getCachedUploads();
        VideoEntry? match;
        if (result case ResultSuccess(data: final videos)) {
          for (final v in videos) {
            if (v.videoId == item.refId) match = v;
          }
        }
        if (match != null && context.mounted) {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => VideoPlayerScreen(video: match!)));
        } else if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'This sermon is no longer in the cache. It may have been removed.')),
          );
        }
        break;
      case BookmarkType.aiConversation:
        context.push('/ai');
        break;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No more sign-in gate — bookmarks are local-first and no longer tied
    // to a uid at all (PROJECT_MIGRATION_AUDIT.md Phase 1). The old
    // bookmarksSignInPrompt ARB string was removed in Phase 2's dead-code
    // pass once nothing referenced it anymore.
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context).bookmarksTitle)),
      body: StreamBuilder<List<BookmarkItem>>(
        stream: ref.watch(bookmarkRepositoryProvider).watchAll(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final bookmarks = snapshot.data ?? [];
          if (bookmarks.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  AppLocalizations.of(context).bookmarksEmpty,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textSecondary(context)),
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: bookmarks.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = bookmarks[index];
              return ListTile(
                leading: Icon(_iconFor(item.type), color: AppColors.accent),
                title: Text(item.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: item.subtitle.isNotEmpty
                    ? Text(item.subtitle,
                        maxLines: 1, overflow: TextOverflow.ellipsis)
                    : null,
                trailing: Text(
                  DateFormat('MMM d').format(item.createdAt),
                  style: TextStyle(
                      fontSize: 11, color: AppTheme.textSecondary(context)),
                ),
                onTap: () => _open(context, item),
              );
            },
          );
        },
      ),
    );
  }
}
