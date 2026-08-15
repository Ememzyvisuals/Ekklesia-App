import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/bookmark_item.dart';

/// Drift-backed replacement for the old Firestore-backed
/// BookmarkRepository (PROJECT_MIGRATION_AUDIT.md Phase 1). No `uid`
/// anywhere — local-first has exactly one on-device user, so the
/// deterministic id collapses from uid+type+refId to just type+refId.
///
/// [watchAll] used to lean on the Firestore SDK's own on-disk cache for
/// offline reads (documented in the old file's header comment). Drift's
/// `.watch()` gives the same "instant local read + live updates"
/// behavior natively, without a network layer to fall back from at all —
/// simpler, not a regression.
class BookmarkRepository {
  BookmarkRepository(this.db);
  final AppDatabase db;

  Stream<List<BookmarkItem>> watchAll() {
    return (db.select(db.bookmarks)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .watch()
        .map((rows) => rows.map(_toItem).toList());
  }

  /// One-shot lookup for a single bookmark button's initial state —
  /// avoids every BookmarkButton instance on a list screen (e.g. the
  /// sermon library) subscribing to the whole bookmarks table just to
  /// know if its one item is saved.
  Future<bool> isBookmarked(BookmarkType type, String refId) async {
    final row = await (db.select(db.bookmarks)
          ..where((t) => t.id.equals(BookmarkItem.deterministicId(type, refId))))
        .getSingleOrNull();
    return row != null;
  }

  Future<void> add(BookmarkItem item) {
    return db.into(db.bookmarks).insertOnConflictUpdate(
          BookmarksCompanion.insert(
            id: BookmarkItem.deterministicId(item.type, item.refId),
            type: item.type.wireName,
            refId: item.refId,
            title: item.title,
            subtitle: Value(item.subtitle),
            language: Value(item.language),
            createdAt: item.createdAt,
          ),
        );
  }

  Future<void> remove(BookmarkType type, String refId) {
    return (db.delete(db.bookmarks)
          ..where((t) => t.id.equals(BookmarkItem.deterministicId(type, refId))))
        .go();
  }

  Future<bool> toggle(BookmarkItem item) async {
    final isSaved = await isBookmarked(item.type, item.refId);
    if (isSaved) {
      await remove(item.type, item.refId);
      return false;
    } else {
      await add(item);
      return true;
    }
  }

  BookmarkItem _toItem(Bookmark row) => BookmarkItem(
        id: row.id,
        type: BookmarkTypeName.fromWireName(row.type),
        refId: row.refId,
        title: row.title,
        subtitle: row.subtitle,
        language: row.language,
        createdAt: row.createdAt,
      );
}
