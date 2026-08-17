import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_theme.dart';
import '../../../core/services/app_settings_service.dart';
import '../../../core/services/program_worker.dart';
import '../../../core/services/verse_worker.dart';
import '../../../core/services/prayer_worker.dart';
import '../../sermons/domain/video_entry.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Landing screen — live/upcoming/recent program card (ProgramWorker),
/// today's verse and prayer (VerseWorker/PrayerWorker), categories, and
/// quick access to Bible, AI assistant, and settings.
///
/// The category grid routes each tile into sermon_library_screen (or
/// /learn for Impact Academy), filtered to that category — see
/// _openCategory below.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static const _categories = [
    ('Sunday Service', Icons.church),
    ('Bible Study', Icons.menu_book),
    ('Global Crusade', Icons.public),
    ('Programs', Icons.calendar_month),
    ('Impact Academy', Icons.school),
  ];

  late Future<ProgramSnapshot> _programFuture;
  late Future<Map<String, dynamic>> _verseFuture;
  late Future<Map<String, dynamic>> _prayerFuture;

  @override
  void initState() {
    super.initState();
    final language = ref.read(languageProvider);
    _programFuture = ProgramWorker.instance.getSnapshot();
    _verseFuture = VerseWorker.instance.getTodaysVerse(language: language);
    _prayerFuture = PrayerWorker.instance.getTodaysPrayer(language: language);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).appTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: AppLocalizations.of(context).commonSearch,
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FutureBuilder<ProgramSnapshot>(
              future: _programFuture,
              builder: (context, snapshot) {
                return _FeaturedCard(snapshot: snapshot.data);
              },
            ),
            const SizedBox(height: 16),
            _DailyContentCard(
              icon: Icons.menu_book,
              label: AppLocalizations.of(context).homeTodaysVerse,
              future: _verseFuture,
              textBuilder: (data) => data['reference'] as String? ?? '',
              onTap: () => context.go('/bible'),
            ),
            const SizedBox(height: 12),
            _DailyContentCard(
              icon: Icons.favorite_outline,
              label: AppLocalizations.of(context).homeTodaysPrayer,
              future: _prayerFuture,
              textBuilder: (data) => data['text'] as String? ?? '',
              maxLines: 3,
              onTap: () => context.go('/ai'),
            ),
            const SizedBox(height: 24),
            Text(AppLocalizations.of(context).homeCategories,
                style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              children: _categories
                  .map((c) => _CategoryTile(
                        label: c.$1,
                        icon: c.$2,
                        onTap: () => _openCategory(context, c.$1),
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  /// Sunday Service / Bible Study / Global Crusade / Programs go to the
  /// sermon library filtered to that category (YouTube-backed); Impact
  /// Academy is a separate content source entirely (Drift/Groq-backed,
  /// not YouTube) so it goes to /learn instead. This was previously
  /// completely unwired — _CategoryTile had no onTap at all, confirmed
  /// on a real device: every one of these 5 tiles did nothing when
  /// tapped.
  ///
  /// "Global Crusade" (this tile's label) maps to sermon_library_screen's
  /// 'GCK' category tab, not a tab literally named "Global Crusade" —
  /// GCK is Deeper Life's own shorthand for "Global Crusade with
  /// Kumuyi." Worth renaming one side or the other for consistency, but
  /// out of scope for wiring the navigation itself.
  void _openCategory(BuildContext context, String label) {
    switch (label) {
      case 'Impact Academy':
        context.push('/learn');
        return;
      case 'Global Crusade':
        context.push('/sermons', extra: 'GCK');
        return;
      default:
        context.push('/sermons', extra: label);
    }
  }
}

/// Live/upcoming/recent program card — replaces the old static "DCLM
/// Radio — Live" placeholder. Still routes to /live on tap (LiveScreen
/// already handles both the radio stream and YouTube live status itself,
/// per its own doc comment — this card doesn't duplicate that player
/// logic, it just surfaces what's live/next/recent from ProgramWorker so
/// the label is accurate instead of hardcoded).
class _FeaturedCard extends StatelessWidget {
  const _FeaturedCard({required this.snapshot});
  final ProgramSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final featured = snapshot?.featured;
    final isLive = featured?.liveStatus == LiveStatus.live;
    final l10n = AppLocalizations.of(context);

    String title;
    String subtitle;
    if (featured != null) {
      title = featured.title;
      subtitle = isLive
          ? l10n.liveNowPlaying
          : featured.liveStatus == LiveStatus.upcoming
              ? l10n.liveStartingSoon
              : 'Recently uploaded — DCLM Radio still live 24/7';
    } else {
      title = l10n.liveRadioDefault;
      subtitle = l10n.liveListenNow;
    }

    return InkWell(
      onTap: () => context.go('/live'),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [AppColors.primary, AppColors.primary]),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(isLive ? Icons.live_tv : Icons.radio,
                color: Colors.white, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.play_circle_fill, color: Colors.white, size: 36),
          ],
        ),
      ),
    );
  }
}

/// Shared card for the Today's Verse / Today's Prayer widgets — both pull
/// from a worker (VerseWorker/PrayerWorker) that already handles the
/// cache -> generate -> offline-fallback chain, so this
/// widget only needs to render whatever `Future` it's given.
class _DailyContentCard extends StatelessWidget {
  const _DailyContentCard({
    required this.icon,
    required this.label,
    required this.future,
    required this.textBuilder,
    required this.onTap,
    this.maxLines = 2,
  });

  final IconData icon;
  final String label;
  final Future<Map<String, dynamic>> future;
  final String Function(Map<String, dynamic>) textBuilder;
  final VoidCallback onTap;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.accent.withValues(alpha: 0.2)),
        ),
        child: FutureBuilder<Map<String, dynamic>>(
          future: future,
          builder: (context, snapshot) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: AppColors.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 4),
                      if (snapshot.connectionState == ConnectionState.waiting)
                        const SizedBox(
                          height: 14,
                          width: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else if (snapshot.hasError || !snapshot.hasData)
                        Text(
                            AppLocalizations.of(context).homeUnavailableOffline,
                            style:
                                const TextStyle(color: AppColors.textSecondary))
                      else
                        Text(
                          textBuilder(snapshot.data!),
                          maxLines: maxLines,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile(
      {required this.label, required this.icon, required this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: AppColors.accent.withValues(alpha: 0.2)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: AppColors.accent, size: 32),
              const SizedBox(height: 8),
              Text(label, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
