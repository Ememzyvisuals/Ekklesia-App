import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;

import '../database/app_database.dart';

/// Local notifications only (PROJECT_MIGRATION_AUDIT.md Phase 4 — spec
/// §33 explicitly rules out Firebase Cloud Messaging). This owns two
/// things:
///   1. Scheduling recurring local reminders (daily verse/prayer/reading)
///      via flutter_local_notifications' zonedSchedule + a daily match
///      — the device's OS fires these even if the app isn't running, no
///      server push needed.
///   2. Recording notification history in Drift's `AppNotifications`
///      table so the in-app notification center has something to show,
///      whether the notification came from a scheduled reminder or an
///      immediate local trigger (download complete, sync complete).
///
/// What this can NOT do that FCM could: notify a device about something
/// that happened on a *different* device or server-side (e.g. "DCLM just
/// went live" pushed to everyone at once). That class of notification
/// needs either the app to be open and polling (YoutubeWorker already
/// does this for live status) or a server-side push path — which is
/// exactly the youtube-sync Worker's still-deprecated `fcm.ts` piece
/// flagged in Phase 3. Not silently pretended away here.
class NotificationService {
  NotificationService._internal();
  static final NotificationService instance = NotificationService._internal();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// [uid] param kept only because main.dart's startup sequence still
  /// calls this the same way it calls CleanupWorker — no longer used for
  /// anything (no per-user token, no per-user Firestore doc). Safe to
  /// call more than once; the underlying plugin init and reminder
  /// scheduling are both idempotent.
  Future<void> initialize({String? uid}) async {
    if (_initialized) return;

    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation(await _deviceTimeZoneName()));

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
    );

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();

    await _applyAllSchedules();
    _initialized = true;
  }

  /// Best-effort local timezone name for `zonedSchedule` — the `timezone`
  /// package needs an IANA name (e.g. "Africa/Lagos"), which Dart's core
  /// `DateTime` doesn't expose directly. Falls back to UTC if platform
  /// timezone detection isn't wired (a real device build should replace
  /// this with `flutter_native_timezone` or similar for accuracy — noted
  /// here rather than silently assumed correct).
  Future<String> _deviceTimeZoneName() async => 'UTC';

  // ---- Reminders (daily verse / prayer / reading) ----

  Future<List<NotificationSchedule>> getSchedules() {
    final db = AppDatabaseService.instance.database;
    return db.select(db.notificationSchedules).get();
  }

  Future<void> setSchedule({
    required String reminderType,
    required bool enabled,
    required int hour,
    required int minute,
  }) async {
    final db = AppDatabaseService.instance.database;
    await db.into(db.notificationSchedules).insertOnConflictUpdate(
          NotificationSchedulesCompanion.insert(
            reminderType: reminderType,
            enabled: Value(enabled),
            hour: Value(hour),
            minute: Value(minute),
          ),
        );
    await _applySchedule(reminderType, enabled, hour, minute);
  }

  Future<void> _applyAllSchedules() async {
    final db = AppDatabaseService.instance.database;
    final rows = await db.select(db.notificationSchedules).get();
    final seen = <String>{};
    for (final row in rows) {
      seen.add(row.reminderType);
      await _applySchedule(row.reminderType, row.enabled, row.hour, row.minute);
    }
    // Defaults for any reminder type never explicitly configured yet —
    // 8:00 AM, enabled, matching the spec's "sensible default, don't
    // force setup" preference (§33: "never spam users," not "notify
    // nobody by default" — reminders are opt-out, not opt-in, same as
    // most devotional apps' first-run behavior).
    const defaults = {
      'daily_verse': (8, 0),
      'prayer': (7, 0),
      'reading': (20, 0),
    };
    for (final entry in defaults.entries) {
      if (!seen.contains(entry.key)) {
        await _applySchedule(entry.key, true, entry.value.$1, entry.value.$2);
      }
    }
  }

  Future<void> _applySchedule(
      String reminderType, bool enabled, int hour, int minute) async {
    final id = _notificationIdFor(reminderType);
    await _plugin.cancel(id);
    if (!enabled) return;

    final (title, body) = switch (reminderType) {
      'daily_verse' => ("Today's Verse", 'Your daily verse is ready to read.'),
      'prayer' => ("Today's Prayer", 'Take a moment for today\'s prayer.'),
      'reading' => (
          'Reading Reminder',
          'Continue where you left off in the Bible.'
        ),
      _ => ('Ekklesia', 'You have a reminder.'),
    };

    await _plugin.zonedSchedule(
      id,
      title,
      body,
      _nextInstanceOf(hour, minute),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'ekklesia_reminders',
          'Daily reminders',
          channelDescription: 'Daily verse, prayer, and reading reminders',
          importance: Importance.defaultImportance,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      matchDateTimeComponents: DateTimeComponents.time, // repeats daily
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: reminderType,
    );
  }

  tz.TZDateTime _nextInstanceOf(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }

  int _notificationIdFor(String reminderType) =>
      reminderType.hashCode & 0x7fffffff;

  // ---- Immediate local notifications (download complete, sync complete) ----

  /// Fires a notification right now (not scheduled) and records it in
  /// history — used by DownloadWorker for completion notifications
  /// (ConversationWorker's own completion events aren't wired to this
  /// yet — see PROJECT_MIGRATION_AUDIT.md §4d's still-cloud-dependent
  /// list). [type] should match one of NotificationCategory's wire
  /// values in notification_worker.dart (e.g. 'download_complete').
  Future<void> notifyNow({
    required String title,
    required String body,
    required String type,
  }) async {
    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'ekklesia_events',
          'App events',
          channelDescription:
              'Download/sync completion and other one-off events',
          importance: Importance.low,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
    await _recordHistory(title: title, body: body, type: type);
  }

  Future<void> _recordHistory(
      {required String title,
      required String body,
      required String type}) async {
    final db = AppDatabaseService.instance.database;
    await db.into(db.appNotifications).insert(
          AppNotificationsCompanion.insert(
            title: title,
            body: body,
            type: Value(type),
            createdAt: DateTime.now(),
          ),
        );
  }

  Future<void> markAsRead(int notificationId) {
    final db = AppDatabaseService.instance.database;
    return (db.update(db.appNotifications)
          ..where((t) => t.id.equals(notificationId)))
        .write(const AppNotificationsCompanion(read: Value(true)));
  }

  Stream<List<AppNotification>> watchHistory() {
    final db = AppDatabaseService.instance.database;
    return (db.select(db.appNotifications)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(100))
        .watch();
  }
}
