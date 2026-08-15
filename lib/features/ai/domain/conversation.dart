/// A single persisted AI chat turn — Drift table `ai_conversations`
/// (PROJECT_MIGRATION_AUDIT.md Phase 4 — was Firestore; see
/// app_database.dart's AiConversations table doc comment for why this
/// migration closed a real security gap, not just a style change).
///
/// No `uid` anymore — one local user, nothing to key conversations by
/// across devices (there's no cross-device sync at all now, which is a
/// real behavior change from the Firestore version: conversation history
/// stays on the device it was created on).
class ConversationMessage {
  const ConversationMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.text,
    required this.createdAt,
  });

  final String id;

  /// Groups messages into one continuous chat thread. A new sessionId is
  /// started when the user explicitly starts a new conversation; otherwise
  /// the app reuses the most recent open session for that day.
  final String sessionId;

  final String role; // 'user' | 'assistant'
  final String text;
  final DateTime createdAt;
}
