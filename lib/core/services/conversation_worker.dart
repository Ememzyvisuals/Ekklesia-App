import '../../features/ai/data/conversation_repository.dart';
import '../../features/ai/domain/conversation.dart';

/// PROJECT_MIGRATION_AUDIT.md Phase 4: `ConversationRepository` is
/// Drift-backed now, not Firestore — a local DB write doesn't fail
/// because the device is offline, so the connectivity-listener /
/// SharedPreferences-queue machinery this class used to own (mirroring
/// the now-deleted SyncWorker's pattern) no longer does anything useful.
/// Kept as a thin pass-through — not deleted outright like SyncWorker —
/// specifically because call sites (ai_assistant_screen.dart) already
/// call `ConversationWorker.instance.record(...)`, and there was no
/// value in churning those call sites in the same pass that fixed the
/// actual security gap (see AiConversations' doc comment in
/// app_database.dart) versus just simplifying what this class does
/// underneath the same call shape.
class ConversationWorker {
  ConversationWorker._internal();
  static final ConversationWorker instance = ConversationWorker._internal();

  /// No-ops now — nothing to start/stop without a queue or connectivity
  /// listener. Kept so main.dart's existing call site doesn't need
  /// touching.
  void start() {}
  void stop() {}

  Future<void> record(ConversationMessage message) =>
      ConversationRepository.instance.save(message);
}
