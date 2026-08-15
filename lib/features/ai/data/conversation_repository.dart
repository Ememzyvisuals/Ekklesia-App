import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/conversation.dart';

/// Drift-backed replacement for the Firestore `ai_conversations`
/// collection (PROJECT_MIGRATION_AUDIT.md Phase 4). Writes are
/// synchronous local DB calls now — no offline-queue-then-flush needed
/// (that was ConversationWorker's job; it's now a thin pass-through, see
/// its own updated doc comment, kept only so call sites that already
/// call `ConversationWorker.instance.record(...)` don't all need editing
/// in the same pass).
class ConversationRepository {
  ConversationRepository._internal();
  static final ConversationRepository instance =
      ConversationRepository._internal();

  AppDatabase get _db => AppDatabaseService.instance.database;

  Stream<List<ConversationMessage>> sessionMessages(String sessionId) {
    return (_db.select(_db.aiConversations)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  /// All sessions, most-recent message first — used for the conversation
  /// history list and as the search corpus.
  Future<List<ConversationMessage>> allMessages({int limit = 500}) async {
    final rows = await (_db.select(_db.aiConversations)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
    return rows.map(_toModel).toList();
  }

  /// Case-insensitive substring search over local history.
  Future<List<ConversationMessage>> search(String query) async {
    if (query.trim().isEmpty) return [];
    final messages = await allMessages();
    final needle = query.toLowerCase();
    return messages
        .where((m) => m.text.toLowerCase().contains(needle))
        .toList();
  }

  Future<void> save(ConversationMessage message) {
    return _db.into(_db.aiConversations).insertOnConflictUpdate(
          AiConversationsCompanion.insert(
            id: message.id,
            sessionId: message.sessionId,
            role: message.role,
            content: message.text,
            createdAt: message.createdAt,
          ),
        );
  }

  Future<void> deleteSession(String sessionId) {
    return (_db.delete(_db.aiConversations)
          ..where((t) => t.sessionId.equals(sessionId)))
        .go();
  }

  ConversationMessage _toModel(AiConversation row) => ConversationMessage(
        id: row.id,
        sessionId: row.sessionId,
        role: row.role,
        text: row.content,
        createdAt: row.createdAt,
      );
}
