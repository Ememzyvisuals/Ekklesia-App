import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'core/config/app_theme.dart';
import 'core/config/app_router.dart';
import 'l10n/generated/app_localizations.dart';
import 'core/services/app_settings_service.dart';
import 'core/database/app_database.dart';
import 'features/profile/data/profile_repository.dart';
import 'core/services/ai_config.dart';
import 'core/services/conversation_worker.dart';
import 'core/services/cleanup_worker.dart';
import 'core/services/notification_service.dart';
import 'core/services/isar_service.dart';
import 'features/sermons/data/youtube_worker.dart';
import 'features/onboarding/presentation/onboarding_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // .env/flutter_dotenv removed (found while auditing CI, not originally
  // planned Phase 5 scope): nothing has read a value out of it since
  // gradio_client.dart (the last thing that used HF_TOKEN) was deleted.
  // Groq's key lives in the groq-proxy Cloudflare Worker's own secret
  // store; YouTube's key is passed at build time via
  // --dart-define=YOUTUBE_API_KEY (see AppConfig.youtubeApiKey). Nothing
  // left for a client-side .env file to hold.

  // Enables lock-screen / notification-shade playback controls for radio
  // and sermon audio — this is the reliability feature the official DCLM
  // app doesn't have.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.ememzyvisuals.ekklesia.audio',
    androidNotificationChannelName: 'Ekklesia Audio',
    androidNotificationOngoing: true,
  );

  // Firebase/Firestore removed entirely — the app is offline-first now.
  // Every feature that used to live in Firestore (notifications, quiz
  // results, AI conversation history, YouTube cache, bookmarks/notes/
  // highlights) is Drift- or asset-backed. See PROJECT_MIGRATION_AUDIT.md
  // for the phase history and OFFLINE_ENGINE.md for the current
  // storage map. The only network calls left anywhere in the app are:
  // the YouTube Data API (sermon library refresh), the Groq API (AI
  // chat), and the live radio stream — all opt-in / on-demand, never
  // required for the app to open or function.

  // Opens the shared Isar database — as of PROJECT_MIGRATION_AUDIT.md
  // Phase 1, this now holds ONLY BibleAudioCacheEntity (TTS cache
  // metadata). Bible verses/books/chapters, bookmarks, highlights, notes,
  // and reading progress/streak moved to Drift (core/database/
  // app_database.dart), which opens itself lazily the first time
  // appDatabaseProvider is read — no explicit await needed here for it,
  // unlike Isar. Requires build_runner to have generated
  // bible_audio_cache_schema.g.dart and app_database.g.dart first (see
  // BIBLE_IMPORT_NOTES.md).
  await IsarService.instance.open();

  // Cache the onboarding-seen flag synchronously for the router's
  // redirect logic (which can't await inside GoRouter's redirect callback
  // without extra plumbing) — read once here before the app builds.
  onboardingSeenCache = await hasSeenOnboarding();

  // SyncWorker removed (PROJECT_MIGRATION_AUDIT.md Phase 4 dead-code
  // finding) — its queueWrite() had zero callers anywhere in the app;
  // ConversationWorker (the only other worker with a similar "queue
  // offline, flush on reconnect" need) already has its own independent
  // queue, never routed through this one. Only .start() was ever
  // called, wiring up a connectivity listener that flushed an always-
  // empty queue. Spec §49 calls this out explicitly: unused
  // machinery gets removed, not kept "just in case."

  // Resolves the live Groq model (primary vs fallback) once before any
  // chat UI is shown — see ai_config.dart. Safe to await here since it
  // fails open (keeps the configured default) rather than blocking on a
  // slow/failed network call.
  await AIConfig.instance.verify();

  // Foreground-interval refresh of the sermon/live-program cache — see
  // youtube_worker.dart's doc comment for why this isn't a true OS-level
  // background worker yet.
  YoutubeWorker().start();

  // Flushes any AI chat turns queued locally while offline, and starts
  // listening for connectivity to flush new ones as they're recorded via
  // ConversationWorker.instance.record(...) (see ai_assistant_screen.dart).
  // Uid-agnostic at startup — queued messages already carry their own uid.
  ConversationWorker.instance.start();

  // CleanupWorker/NotificationService need a stable local identifier,
  // which isn't available yet at this point for a fresh install
  // (onboarding runs first). Run cleanup once per app-open after a
  // profile exists instead of on a timer here — cheap, idempotent, and
  // doesn't need a second background scheduler.
  //
  // PROJECT_MIGRATION_AUDIT.md Phase 2: this used to key off
  // AuthService.authStateChanges (Firebase Auth). Firebase Auth is gone
  // — CleanupWorker/NotificationService still take a `uid` parameter
  // because their own backing stores (Firestore, in NotificationService's
  // case) haven't migrated to Drift yet; LocalProfile.id is passed in
  // its place as a stable per-device identifier. Once those stores move
  // to Drift, the `uid` parameter itself should go away, not just its
  // source.
  //
  // NotificationService.initialize sets up local notification
  // permissions + schedules the daily verse/prayer/reading reminders
  // (spec §33 — local notifications only, no FCM, as of
  // PROJECT_MIGRATION_AUDIT.md Phase 4). Found uncalled from anywhere in
  // the app before this was wired up — without it, users were never
  // prompted for notification permission and no reminder was ever
  // scheduled, so every notification the spec calls for would have
  // silently never fired.
  ProfileRepository(AppDatabaseService.instance.database)
      .watch()
      .listen((profile) {
    if (profile != null) {
      // LocalIdentity removed (PROJECT_MIGRATION_AUDIT.md Phase 4 —
      // notifications/quiz/AI-conversations/search all migrated to
      // local Drift storage this same pass, so nothing reads a
      // per-device identity anymore; it was dead code the moment the
      // last of those four call sites was migrated).
      CleanupWorker.instance.runOnce(uid: profile.id);
      NotificationService.instance.initialize(uid: profile.id);
    }
  });

  runApp(const ProviderScope(child: EkklesiaApp()));
}

class EkklesiaApp extends ConsumerWidget {
  const EkklesiaApp({super.key});

  /// Maps LanguageNotifier's app-internal language keys (also used by
  /// EkklesiaLanguage.code for TTS/Bible) to actual Locale codes. Nigerian
  /// Pidgin's ISO 639-3 code is `pcm` — not a typo, that's the real code
  /// (there's no ISO 639-1 two-letter code for Pidgin).
  Locale _localeFor(String languageKey) {
    switch (languageKey) {
      case 'yoruba':
        return const Locale('yo');
      case 'hausa':
        return const Locale('ha');
      case 'igbo':
        return const Locale('ig');
      case 'pidgin':
        return const Locale('pcm');
      case 'english':
      default:
        return const Locale('en');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final language = ref.watch(languageProvider);

    return MaterialApp.router(
      title: 'Ekklesia',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: appRouter,
      locale: _localeFor(language),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
    );
  }
}
