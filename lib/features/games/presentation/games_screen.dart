import 'dart:io';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_theme.dart';
import '../../../core/shared/result.dart';
import '../data/games_repository.dart';
import '../data/local_games_repository.dart';
import '../data/game_import_service.dart';
import '../domain/game_entry.dart';
import 'game_webview_screen.dart';

class GamesScreen extends StatefulWidget {
  const GamesScreen({super.key});

  @override
  State<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends State<GamesScreen> {
  const _repository = GamesRepository();
  Result<List<GameEntry>> _result = const Result.loading();
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Bundled (online-catalog) games and user-imported (offline) games
  /// come from two entirely separate sources — this is the one place
  /// they're merged into a single grid, local games first so a user who
  /// just imported something sees it immediately.
  Future<void> _load() async {
    setState(() => _result = const Result.loading());
    final bundledResult = await _repository.fetchCatalog();
    final localGames = await LocalGamesRepository.instance.getAll();
    if (!mounted) return;
    switch (bundledResult) {
      case ResultSuccess(data: final bundled):
        setState(() => _result = Result.success([...localGames, ...bundled]));
      case ResultFailure():
        // Bundled catalog failed to load (shouldn't normally happen — it's
        // a bundled asset) — still show whatever local games exist rather
        // than blocking the whole screen on an unrelated failure.
        setState(() => _result = Result.success(localGames));
      case ResultLoading():
        break;
    }
  }

  Future<void> _openGame(GameEntry game) async {
    if (game.isLocal) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => GameWebViewScreen(
          title: game.title,
          localIndexFilePath: game.indexFilePath,
        ),
      ));
      return;
    }
    if (game.isEmbeddable) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            GameWebViewScreen(title: game.title, url: game.embedUrl!),
      ));
      return;
    }
    if (game.launchUrl != null) {
      final uri = Uri.parse(game.launchUrl!);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }

  Future<void> _importGame() async {
    setState(() => _importing = true);
    final result = await GameImportService.instance.pickAndImport();
    if (!mounted) return;
    setState(() => _importing = false);
    switch (result) {
      case ResultSuccess(data: final game):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Imported "${game.title}"')),
        );
        _load();
      case ResultFailure(failure: final f):
        // Empty message + non-retryable means the user just cancelled
        // the file picker — nothing went wrong, so nothing to say.
        if (f.message.isEmpty) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(f.message)));
      case ResultLoading():
        break;
    }
  }

  Future<void> _deleteLocalGame(GameEntry game) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove game?'),
        content: Text('"${game.title}" will be removed from this device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    await GameImportService.instance.deleteImportedGame(game);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Games'),
        actions: [
          IconButton(
            icon: _importing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add_to_photos_outlined),
            tooltip: 'Import a game (.zip)',
            onPressed: _importing ? null : _importGame,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: switch (_result) {
          ResultLoading() => const Center(child: CircularProgressIndicator()),
          ResultFailure(failure: final f) =>
            _ErrorState(message: f.message, onRetry: _load),
          ResultSuccess(data: final games) => games.isEmpty
              ? _EmptyState(onImport: _importGame)
              : _GameGrid(
                  games: games,
                  onTap: _openGame,
                  onLongPressLocal: _deleteLocalGame,
                ),
        },
      ),
    );
  }
}

/// Genuine empty state — not a placeholder screen pretending games exist.
/// This is the real, expected state of the feature until entries are added
/// to the bundled `assets/data/games.json` catalog.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onImport});
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        Icon(Icons.videogame_asset_outlined,
            size: 56, color: AppTheme.textSecondary(context)),
        const SizedBox(height: 20),
        Center(
          child: Text('No games yet',
              style: AppTypography.titleMedium(
                  color: AppTheme.textPrimary(context))),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            'Online games are only added where the developer has granted '
            'permission to link or embed — nothing scraped. Or import your '
            'own packaged HTML5 game (.zip with an index.html) to play it '
            'fully offline.',
            textAlign: TextAlign.center,
            style: AppTypography.bodyMedium(
                color: AppTheme.textSecondary(context)),
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: OutlinedButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.add_to_photos_outlined),
            label: const Text('Import a game'),
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        const Icon(Icons.wifi_off, size: 48, color: AppColors.error),
        const SizedBox(height: 16),
        Center(child: Text(message, textAlign: TextAlign.center)),
        const SizedBox(height: 16),
        Center(
            child:
                ElevatedButton(onPressed: onRetry, child: const Text('Retry'))),
      ],
    );
  }
}

class _GameGrid extends StatelessWidget {
  const _GameGrid({
    required this.games,
    required this.onTap,
    required this.onLongPressLocal,
  });
  final List<GameEntry> games;
  final ValueChanged<GameEntry> onTap;
  final ValueChanged<GameEntry> onLongPressLocal;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.78,
      ),
      itemCount: games.length,
      itemBuilder: (context, i) {
        final game = games[i];
        return GestureDetector(
          onTap: () => onTap(game),
          // Local (imported) games can be removed; bundled catalog
          // entries can't — there's nothing on-device to delete for
          // those, only a JSON row shipped in the app itself.
          onLongPress: game.isLocal ? () => onLongPressLocal(game) : null,
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.surface(context),
              borderRadius: BorderRadius.circular(20),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 1.4,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _GameThumbnail(game: game),
                      if (game.isLocal)
                        const Positioned(
                          top: 6,
                          left: 6,
                          child: _OfflineBadge(),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(game.title,
                          style: AppTypography.titleSmall(
                              color: AppTheme.textPrimary(context)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text('${game.category} · ${game.ageRating}',
                          style: AppTypography.caption(
                              color: AppTheme.textSecondary(context))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Local bundles are shown from their extracted thumbnail file (if the
/// bundle included one); bundled-catalog entries keep the existing
/// cached-network-image path. Never mixes the two sources.
class _GameThumbnail extends StatelessWidget {
  const _GameThumbnail({required this.game});
  final GameEntry game;

  @override
  Widget build(BuildContext context) {
    if (game.isLocal) {
      final path = game.thumbnailPath;
      if (path != null) {
        return Image.file(
          File(path),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallback(),
        );
      }
      return _fallback();
    }
    return CachedNetworkImage(
      imageUrl: game.thumbnailUrl,
      fit: BoxFit.cover,
      placeholder: (_, __) => Container(color: AppColors.secondary),
      errorWidget: (_, __, ___) => _fallback(),
    );
  }

  Widget _fallback() => Container(
        color: AppColors.secondary,
        child: const Icon(Icons.videogame_asset_outlined),
      );
}

class _OfflineBadge extends StatelessWidget {
  const _OfflineBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.offline_bolt, size: 12, color: Colors.white),
          SizedBox(width: 3),
          Text('Offline',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
