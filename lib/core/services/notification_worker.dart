import 'dart:async';

import '../database/app_database.dart';
import 'notification_service.dart';

/// Sits on top of [NotificationService] (which owns local-notification
/// scheduling and Drift-backed history — see its header comment,
/// PROJECT_MIGRATION_AUDIT.md Phase 4) and turns the raw notification
/// history table into something the UI can consume directly: categorized
/// by type, with an unread count — without re-fetching or re-subscribing
/// per screen.
enum NotificationCategory {
  todaysVerse,
  todaysPrayer,
  liveProgram,
  upcomingProgram,
  downloadComplete,
  syncComplete,
  other,
}

class CategorizedNotification {
  const CategorizedNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.category,
    required this.read,
    required this.createdAt,
  });

  final int id;
  final String title;
  final String body;
  final NotificationCategory category;
  final bool read;
  final DateTime createdAt;

  factory CategorizedNotification.fromRow(AppNotification row) =>
      CategorizedNotification(
        id: row.id,
        title: row.title,
        body: row.body,
        category: _categorize(row.type),
        read: row.read,
        createdAt: row.createdAt,
      );

  static NotificationCategory _categorize(String type) {
    switch (type) {
      case 'daily_verse':
      case 'todays_verse':
        return NotificationCategory.todaysVerse;
      case 'prayer':
      case 'todays_prayer':
        return NotificationCategory.todaysPrayer;
      case 'live_program':
        return NotificationCategory.liveProgram;
      case 'upcoming_program':
        return NotificationCategory.upcomingProgram;
      case 'download_complete':
        return NotificationCategory.downloadComplete;
      case 'sync_complete':
        return NotificationCategory.syncComplete;
      default:
        return NotificationCategory.other;
    }
  }
}

class NotificationWorker {
  NotificationWorker._internal();
  static final NotificationWorker instance = NotificationWorker._internal();

  /// [uid] param kept for call-site compatibility with the pre-Phase-4
  /// signature — no longer used, since notification history
  /// isn't keyed by user anymore (one local user, one history table).
  Stream<List<CategorizedNotification>> stream(String? uid) {
    return NotificationService.instance
        .watchHistory()
        .map((rows) => rows.map(CategorizedNotification.fromRow).toList());
  }

  int unreadCount(List<CategorizedNotification> notifications) =>
      notifications.where((n) => !n.read).length;

  Future<void> markAsRead(int notificationId) =>
      NotificationService.instance.markAsRead(notificationId);
}
