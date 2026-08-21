import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/config/app_theme.dart';
import '../../../core/services/notification_worker.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Notifications screen — the UI half of NotificationWorker, categorizing
/// + deduping NotificationService's local notification history (Drift-
/// backed, no FCM — PROJECT_MIGRATION_AUDIT.md Phase 4, spec §33).
///
/// This screen renders history of notifications that already fired
/// (scheduled reminders, download-complete events) — it doesn't create
/// them; see notification_service.dart for what schedules/fires them.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  IconData _iconFor(NotificationCategory category) {
    switch (category) {
      case NotificationCategory.todaysVerse:
        return Icons.menu_book;
      case NotificationCategory.todaysPrayer:
        return Icons.favorite_outline;
      case NotificationCategory.liveProgram:
        return Icons.live_tv;
      case NotificationCategory.upcomingProgram:
        return Icons.event;
      case NotificationCategory.downloadComplete:
        return Icons.download_done;
      case NotificationCategory.syncComplete:
        return Icons.sync;
      case NotificationCategory.other:
        return Icons.notifications_none;
    }
  }

  @override
  Widget build(BuildContext context) {
    // No more uid gate (PROJECT_MIGRATION_AUDIT.md Phase 4) — notification
    // history is Drift-backed and local now, nothing to wait on a
    // profile load for.
    return Scaffold(
      appBar:
          AppBar(title: Text(AppLocalizations.of(context).notificationsTitle)),
      body: StreamBuilder<List<CategorizedNotification>>(
        stream: NotificationWorker.instance.stream(null),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not load notifications: ${snapshot.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            );
          }
          final notifications = snapshot.data ?? [];
          if (notifications.isEmpty) {
            return Center(
              child: Text(
                AppLocalizations.of(context).notificationsEmpty,
                style: TextStyle(color: AppTheme.textSecondary(context)),
              ),
            );
          }
          return ListView.separated(
            itemCount: notifications.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final n = notifications[index];
              return ListTile(
                leading: Icon(
                  _iconFor(n.category),
                  color: n.read
                      ? AppTheme.textSecondary(context)
                      : AppColors.primary,
                ),
                title: Text(
                  n.title,
                  style: TextStyle(
                    fontWeight: n.read ? FontWeight.normal : FontWeight.bold,
                  ),
                ),
                subtitle: Text(n.body),
                trailing: Text(
                  DateFormat('MMM d, h:mm a').format(n.createdAt),
                  style: TextStyle(
                      fontSize: 11, color: AppTheme.textSecondary(context)),
                ),
                onTap: n.read
                    ? null
                    : () => NotificationWorker.instance.markAsRead(n.id),
              );
            },
          );
        },
      ),
    );
  }
}
