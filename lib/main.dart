import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoLocalizations;
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
  //
  // Timeout-guarded (see the same reasoning on IsarService.open() below):
  // a native platform-channel call hanging here would freeze the splash
  // screen forever with zero error, zero crash, before runApp() is ever
  // reached — exactly what got reported after the first real-device
  // install. Losing lock-screen audio controls on a device where this
  // genuinely can't initialize is a minor, recoverable degradation; an
  // app that never opens is not.
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.ememzyvisuals.ekklesia.audio',
      androidNotificationChannelName: 'Ekklesia Audio',
      androidNotificationOngoing: true,
    ).timeout(const Duration(seconds: 5));
  } catch (_) {
    // Audio still plays without this — only lock-screen/notification
    // controls are lost, never worth blocking app startup over.
  }

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
  //
  // Timeout-guarded for the same reason as JustAudioBackground.init
  // above: native library loading (isar_community_flutter_libs) hanging
  // here — rather than throwing — would silently freeze startup with no
  // way to diagnose it from the UI. Audio caching degrades (TTS
  // re-generates instead of reading a cache) rather than the whole app
  // becoming unusable.
  try {
    await IsarService.instance.open().timeout(const Duration(seconds: 8));
  } catch (_) {
    // Bible audio caching won't work this session, but nothing else in
    // the app depends on Isar anymore (see comment above) — everything
    // else is Drift-backed and opens independently.
  }

  // Cache the onboarding-seen flag synchronously for the router's
  // redirect logic (which can't await inside GoRouter's redirect callback
  // without extra plumbing) — read once here before the app builds.
  //
  // Timeout-guarded: a SharedPreferences read should never realistically
  // hang, but "should never" was true of every other call in this
  // function too until a real device proved otherwise. Defaulting to
  // `false` on timeout just means an already-onboarded user sees
  // onboarding again once — mildly annoying, never app-breaking.
  try {
    onboardingSeenCache =
        await hasSeenOnboarding().timeout(const Duration(seconds: 3));
  } catch (_) {
    onboardingSeenCache = false;
  }

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
    final fontScale = ref.watch(fontScaleProvider);

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
        _FallbackMaterialLocalizationsDelegate(),
        _FallbackCupertinoLocalizationsDelegate(),
        _FallbackWidgetsLocalizationsDelegate(),
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      // Applies the font-size preference (fontScaleProvider, set from
      // the Bible screen's "Aa" control or Settings) to every screen in
      // the app at once, rather than each screen having to remember to
      // read it individually — the specific, named request was making
      // the Bible easier to read for older users, and text-scaling the
      // whole app is both simpler to implement correctly and more
      // consistent than a Bible-only special case would have been.
      // MediaQuery.withClampedTextScaling isn't used here because it
      // multiplies against the OS's own accessibility text-scale
      // setting; TextScaler.linear replaces it outright, which is the
      // right behavior for an in-app preference the person sets
      // directly rather than one meant to layer on top of system
      // settings.
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(fontScale),
          ),
          child: child!,
        );
      },
    );
  }
}

// Confirmed real, well-documented Flutter issue (not speculation — see
// commit message / PR description for the sources): Yoruba, Igbo, and
// Hausa are NOT among the ~80 languages Flutter's own
// GlobalMaterialLocalizations/GlobalCupertinoLocalizations/
// GlobalWidgetsLocalizations ship built-in translations for (see
// kMaterialSupportedLanguages in the flutter_localizations package).
// Forcing `locale:` directly to one of those unsupported codes — which
// this app must do, since AppLocalizations.delegate (our own, custom
// generated from lib/l10n/*.arb) DOES support them and needs the
// correct locale to resolve the right translations — left Flutter's
// framework-level delegates unable to resolve anything for that locale.
// Confirmed on a real device: switching to Igbo, the app's own
// translated text (verse, prayer, category labels) rendered correctly,
// while the bottom navigation area — which leans on Material internals
// like NavigationDestination's tooltips, which call
// MaterialLocalizations.of(context) — collapsed into a blank area.
//
// Each delegate below: reports itself as "supported" for every locale
// (so Localizations never rejects the locale outright), but actually
// loads the real translations only for locales Flutter genuinely ships;
// for anything else (yo/ha/ig/pcm), it loads English instead. This
// means a few framework-level strings a person is unlikely to ever
// closely read (default dialog button labels, some accessibility
// tooltips) show in English for these four languages, which is a minor,
// honest degradation — infinitely better than the previous outcome,
// which was large sections of the app becoming unusable.
class _FallbackMaterialLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const _FallbackMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) {
    final effective = GlobalMaterialLocalizations.delegate.isSupported(locale)
        ? locale
        : const Locale('en');
    return GlobalMaterialLocalizations.delegate.load(effective);
  }

  @override
  bool shouldReload(_FallbackMaterialLocalizationsDelegate old) => false;
}

class _FallbackCupertinoLocalizationsDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const _FallbackCupertinoLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<CupertinoLocalizations> load(Locale locale) {
    final effective = GlobalCupertinoLocalizations.delegate.isSupported(locale)
        ? locale
        : const Locale('en');
    return GlobalCupertinoLocalizations.delegate.load(effective);
  }

  @override
  bool shouldReload(_FallbackCupertinoLocalizationsDelegate old) => false;
}

class _FallbackWidgetsLocalizationsDelegate
    extends LocalizationsDelegate<WidgetsLocalizations> {
  const _FallbackWidgetsLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<WidgetsLocalizations> load(Locale locale) {
    final effective = GlobalWidgetsLocalizations.delegate.isSupported(locale)
        ? locale
        : const Locale('en');
    return GlobalWidgetsLocalizations.delegate.load(effective);
  }

  @override
  bool shouldReload(_FallbackWidgetsLocalizationsDelegate old) => false;
}
