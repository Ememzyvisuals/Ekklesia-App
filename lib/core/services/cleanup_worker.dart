import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';

import '../database/app_database.dart';

/// Periodic housekeeping: removes orphaned local files (partial/cancelled
/// downloads) and prunes old local notification history — everything
/// this app stores now lives on-device, so every step here is a local
/// file/DB operation, never a network call.
///
/// PROJECT_MIGRATION_AUDIT.md Phase 4: notification history moved to
/// Drift (Phase 4's notification_service.dart rewrite), so pruning it is
/// a local DELETE now, not a Firestore batch. Firebase/Firestore has
/// since been removed from the app entirely (see main.dart).
///
/// TTS error log pruning and the Bible-audio-cache reconciliation step
/// (`_pruneOrphanedBibleAudio`) were REMOVED along with TTS itself (see
/// pubspec.yaml's removal notes) — `tts_error_logger.dart` and
/// `bible_audio_cache.dart` are both gone, and there's no longer any
/// TTS-generated cache to reconcile.
///
/// This does NOT touch a user's completed Downloads (see DownloadWorker) —
/// only files explicitly marked temp/orphaned, and notification data
/// that's operational, not user content.
class CleanupWorker {
  CleanupWorker._internal();
  static final CleanupWorker instance = CleanupWorker._internal();

  static const _maxNotificationAge = Duration(days: 30);
  static const _maxTempFileAge = Duration(days: 3);

  /// Runs one full pass. Safe to call repeatedly (e.g. once per app
  /// launch, or on an interval via a foreground timer in main.dart) —
  /// every step is independently no-op if there's nothing to clean.
  ///
  /// [uid] kept for call-site compatibility with main.dart's existing
  /// `CleanupWorker.instance.runOnce(uid: profile.id)` call — no longer
  /// used for anything, since notification history isn't filtered by
  /// user anymore (one local user, one history table).
  Future<void> runOnce({String? uid}) async {
    await Future.wait([
      _pruneOldNotifications(),
      _pruneOrphanedTempFiles(),
    ]);
  }

  Future<void> _pruneOldNotifications() async {
    try {
      final db = AppDatabaseService.instance.database;
      final cutoff = DateTime.now().subtract(_maxNotificationAge);
      await (db.delete(db.appNotifications)
            ..where((t) => t.createdAt.isSmallerThanValue(cutoff)))
          .go();
    } catch (_) {
      // Best-effort housekeeping — never surface this to the user.
    }
  }

  /// Deletes files under the app's temp directory whose extension marks
  /// them as in-progress downloads (`.part`) older than [_maxTempFileAge] —
  /// these are downloads that were cancelled/crashed mid-transfer and
  /// never got promoted to a completed file by DownloadWorker.
  Future<void> _pruneOrphanedTempFiles() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final downloadsTempDir = Directory('${tempDir.path}/downloads_tmp');
      if (!await downloadsTempDir.exists()) return;

      final cutoff = DateTime.now().subtract(_maxTempFileAge);
      await for (final entity in downloadsTempDir.list()) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          try {
            await entity.delete();
          } catch (_) {
            // File may be actively being written by an in-flight download —
            // skip it this pass rather than risk corrupting a live transfer.
          }
        }
      }
    } catch (_) {
      // Platform without a temp dir concept, or permission issue — no-op.
    }
  }
}
