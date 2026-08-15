import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_theme.dart';
import '../data/bookmark_providers.dart';
import '../domain/bookmark_item.dart';

/// Drop-in bookmark toggle for any screen — checks initial state once on
/// mount, then flips optimistically on tap (reverting if the write
/// fails). Used by video_player_screen.dart (sermons) and
/// bible_screen.dart (passages); the AI conversation history list is the
/// other place [BookmarkType.aiConversation] applies, wired the same way
/// when that list view exists.
///
/// No longer gated on AuthService/uid (PROJECT_MIGRATION_AUDIT.md Phase 1
/// — BookmarkRepository is Drift-backed and uid-free now that there's one
/// local user, not many synced accounts sharing a Firestore collection).
/// This makes bookmarking work even before Phase 2 formally removes
/// Firebase Auth from the rest of the app.
class BookmarkButton extends ConsumerStatefulWidget {
  const BookmarkButton({
    super.key,
    required this.type,
    required this.refId,
    required this.title,
    this.subtitle = '',
    this.language,
  });

  final BookmarkType type;
  final String refId;
  final String title;
  final String subtitle;
  final String? language;

  @override
  ConsumerState<BookmarkButton> createState() => _BookmarkButtonState();
}

class _BookmarkButtonState extends ConsumerState<BookmarkButton> {
  bool? _isBookmarked; // null while loading initial state
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadInitialState();
  }

  Future<void> _loadInitialState() async {
    final saved = await ref
        .read(bookmarkRepositoryProvider)
        .isBookmarked(widget.type, widget.refId);
    if (mounted) {
      setState(() => _isBookmarked = saved);
    }
  }

  Future<void> _toggle() async {
    if (_busy || _isBookmarked == null) {
      return;
    }

    final previous = _isBookmarked!;
    setState(() {
      _isBookmarked = !previous; // optimistic
      _busy = true;
    });

    try {
      final nowSaved =
          await ref.read(bookmarkRepositoryProvider).toggle(BookmarkItem(
                id: '', // ignored — deterministicId is recomputed in the repository
                type: widget.type,
                refId: widget.refId,
                title: widget.title,
                subtitle: widget.subtitle,
                language: widget.language,
                createdAt: DateTime.now(),
              ));
      if (mounted) {
        setState(() => _isBookmarked = nowSaved);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isBookmarked = previous); // revert on failure
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isBookmarked == null) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: Padding(
          padding: EdgeInsets.all(8.0),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return IconButton(
      onPressed: _busy ? null : _toggle,
      icon: Icon(
        _isBookmarked! ? Icons.bookmark : Icons.bookmark_border,
        color: _isBookmarked! ? AppColors.accent : null,
      ),
      tooltip: _isBookmarked! ? 'Remove bookmark' : 'Bookmark this',
    );
  }
}
