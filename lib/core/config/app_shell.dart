import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'radio_mini_player.dart';

/// The persistent bottom-nav shell for the app's 5 primary tabs — Home,
/// Bible, Games, AI, Settings.
///
/// Before this: every screen (HomeScreen, BibleScreen, SettingsScreen,
/// AiAssistantScreen, GamesScreen) was its own independent top-level
/// GoRoute, and only HomeScreen happened to have a `NavigationBar`
/// hand-built into its own Scaffold — nowhere else did. Confirmed on a
/// real device: leaving Home meant landing on a screen with no nav bar
/// at all and no way back to it except force-closing the app, because
/// `context.go(...)` (used by that one hand-built nav bar) replaces the
/// navigation stack rather than pushing onto it — there was nothing to
/// pop back to even via the system back button.
///
/// `StatefulShellRoute.indexedStack` (wired up in app_router.dart) is
/// the fix: one nav bar, rendered once here, shared across all 5 tabs,
/// with each tab's own navigation stack preserved via IndexedStack when
/// switching away and back. Games is a genuinely new tab, not a
/// pre-existing one moved — it was previously reachable only by opening
/// Settings first, which is exactly the "no games tab, I have to go to
/// settings to open games" gap flagged directly by the person building
/// this app.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Radio mini-player sits above the tab bar, visible on every
          // tab once playback starts — renders nothing at all otherwise
          // (see RadioMiniPlayer's own doc comment for why this exists).
          const RadioMiniPlayer(),
          NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: (index) {
              // goBranch with initialLocation:true when re-tapping the
              // already-selected tab resets that tab back to its own root
              // (standard bottom-nav behavior — e.g. tapping "Bible" again
              // while already deep in a chapter goes back to the book
              // list), while switching tabs preserves each one's own stack.
              navigationShell.goBranch(
                index,
                initialLocation: index == navigationShell.currentIndex,
              );
            },
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
              NavigationDestination(
                  icon: Icon(Icons.menu_book), label: 'Bible'),
              NavigationDestination(
                  icon: Icon(Icons.videogame_asset_outlined), label: 'Games'),
              NavigationDestination(icon: Icon(Icons.smart_toy), label: 'AI'),
              NavigationDestination(
                  icon: Icon(Icons.settings), label: 'Settings'),
            ],
          ),
        ],
      ),
    );
  }
}
