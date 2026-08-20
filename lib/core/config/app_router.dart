import 'package:go_router/go_router.dart';

import 'app_shell.dart';
import '../../features/onboarding/presentation/onboarding_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/home/presentation/live_screen.dart';
import '../../features/bible/presentation/bible_screen.dart';
import '../../features/learn/presentation/learn_screen.dart';
import '../../features/ai/presentation/ai_assistant_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/games/presentation/games_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/sermons/presentation/sermon_library_screen.dart';
import '../../features/downloads/presentation/downloads_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/bookmarks/presentation/bookmarks_screen.dart';
import '../../features/settings/presentation/network_diagnostics_screen.dart';
import '../../features/games/presentation/bible_quiz_game_screen.dart';
import '../../features/search/presentation/search_screen.dart';

/// Gateway logic (PROJECT_MIGRATION_AUDIT.md Phase 2 — no account system,
/// so no signed-in/signed-out gate anymore):
///   1. If onboarding + local profile creation hasn't been completed ->
///      /onboarding
///   2. Else -> allow straight into the main app, no network required.
///
/// [onboardingSeenCache] is checked synchronously via a cached flag set
/// by main.dart at startup (see main.dart) to avoid an async redirect
/// race — same mechanism as before, just no longer paired with a second,
/// separate Firebase-auth gate. OnboardingScreen only sets this flag
/// AFTER it successfully writes a LocalProfile row (see
/// onboarding_screen.dart's _finish()), so "onboarding seen" and "profile
/// exists" are the same fact now, not two things that could disagree.
bool onboardingSeenCache = false;

final GoRouter appRouter = GoRouter(
  initialLocation: '/onboarding',
  redirect: (context, state) {
    final goingToOnboarding = state.matchedLocation == '/onboarding';

    if (!onboardingSeenCache && !goingToOnboarding) {
      return '/onboarding';
    }
    if (onboardingSeenCache && goingToOnboarding) {
      return '/home';
    }
    return null;
  },
  routes: [
    GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen()),

    // The 5 primary tabs share one persistent bottom nav bar (AppShell)
    // via StatefulShellRoute — see app_shell.dart's doc comment for why
    // this replaced 5 independent top-level GoRoutes that had no shared
    // navigation at all. Each branch keeps its own navigation stack
    // (IndexedStack under the hood), so pushing a detail screen from,
    // say, the Bible tab and switching to Settings and back preserves
    // where you were in Bible.
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(routes: [
          GoRoute(
              path: '/home', builder: (context, state) => const HomeScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
              path: '/bible', builder: (context, state) => const BibleScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
              path: '/games', builder: (context, state) => const GamesScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
              path: '/ai',
              builder: (context, state) => AiAssistantScreen(
                  initialMessage: state.extra is String
                      ? state.extra as String
                      : null)),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsScreen()),
        ]),
      ],
    ),

    // Everything below is a normal pushed route reached FROM inside a
    // tab (e.g. tapping a category card on Home, or a message in
    // Impact Academy) — Flutter's default Scaffold/AppBar already gives
    // these a working back button since they're pushed onto the stack,
    // not swapped in as a 6th tab.
    GoRoute(path: '/live', builder: (context, state) => const LiveScreen()),
    GoRoute(path: '/learn', builder: (context, state) => const LearnScreen()),
    GoRoute(
        path: '/profile', builder: (context, state) => const ProfileScreen()),
    GoRoute(
        path: '/sermons',
        builder: (context, state) {
          final category = state.extra is String ? state.extra as String : null;
          return SermonLibraryScreen(initialCategory: category);
        }),
    GoRoute(
        path: '/downloads',
        builder: (context, state) => const DownloadsScreen()),
    GoRoute(
        path: '/notifications',
        builder: (context, state) => const NotificationsScreen()),
    GoRoute(
        path: '/bookmarks',
        builder: (context, state) => const BookmarksScreen()),
    GoRoute(
        path: '/network-diagnostics',
        builder: (context, state) => const NetworkDiagnosticsScreen()),
    GoRoute(
        path: '/bible-quiz',
        builder: (context, state) => const BibleQuizGameScreen()),
    GoRoute(path: '/search', builder: (context, state) => const SearchScreen()),
  ],
);
