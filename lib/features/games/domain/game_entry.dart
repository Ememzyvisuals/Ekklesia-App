/// One entry in the Games catalog, from either of two sources:
///
/// 1. The bundled `assets/data/games.json` catalog — developer-curated,
///    [launchUrl] (external browser) or [embedUrl] (in-app WebView),
///    always online since it's fetching from a remote host. There is no
///    automated source for this list, because no free, legitimately-
///    licensed "biblical games API" exists (verified: trivia APIs are
///    either general-knowledge/non-Bible, or CC-BY-NC non-commercial
///    only; Bible-specific HTML5 games are one-time-purchase files, not
///    APIs). Adding one means editing that JSON file and shipping a new
///    build.
/// 2. A user-imported local bundle (see GameImportService /
///    LocalGamesRepository) — [indexFilePath] points at an extracted
///    `index.html` already on disk, so play never touches the network at
///    all, before or after import.
///
/// A given entry is exactly one of these — never both a remote source and
/// [indexFilePath] at once.
class GameEntry {
  const GameEntry({
    required this.id,
    required this.title,
    required this.description,
    required this.thumbnailUrl,
    required this.category,
    required this.ageRating,
    required this.developer,
    this.launchUrl,
    this.embedUrl,
    this.indexFilePath,
    this.thumbnailPath,
  });

  final String id;
  final String title;
  final String description;
  /// Remote thumbnail URL (bundled catalog entries only). Empty for local
  /// entries — see [thumbnailPath] instead.
  final String thumbnailUrl;
  final String category;
  final String ageRating;
  final String developer;

  /// Set when the publisher has NOT granted in-app embedding — opens in the
  /// device's external browser instead.
  final String? launchUrl;

  /// Set only when the publisher has explicitly granted embedding
  /// permission — opens inside the app's WebView.
  final String? embedUrl;

  /// Set only for a user-imported local game — an absolute on-device path
  /// to the extracted bundle's `index.html`. When set, the game plays
  /// fully offline via WebViewController.loadFile; [launchUrl]/[embedUrl]
  /// are never set alongside this.
  final String? indexFilePath;

  /// Absolute on-device path to a thumbnail extracted from the local
  /// bundle, if it had one. Local-entries-only counterpart to
  /// [thumbnailUrl].
  final String? thumbnailPath;

  bool get isEmbeddable => embedUrl != null && embedUrl!.isNotEmpty;
  bool get isLocal => indexFilePath != null && indexFilePath!.isNotEmpty;

  factory GameEntry.fromJson(Map<String, dynamic> data) {
    return GameEntry(
      id: data['id'] as String,
      title: data['title'] as String? ?? 'Untitled',
      description: data['description'] as String? ?? '',
      thumbnailUrl: data['thumbnailUrl'] as String? ?? '',
      category: data['category'] as String? ?? 'General',
      ageRating: data['ageRating'] as String? ?? 'All ages',
      developer: data['developer'] as String? ?? 'Unknown',
      launchUrl: data['launchUrl'] as String?,
      embedUrl: data['embedUrl'] as String?,
    );
  }

  /// Builds an entry from a `LocalGames` Drift row (see
  /// LocalGamesRepository) — kept here, not in the repository, so the
  /// mapping between the DB row shape and the domain shape lives next to
  /// the domain class itself, matching ArchivedMessage.fromRow's pattern.
  factory GameEntry.fromLocalRow({
    required String id,
    required String title,
    required String description,
    required String category,
    required String ageRating,
    required String developer,
    required String indexFilePath,
    String? thumbnailPath,
  }) {
    return GameEntry(
      id: id,
      title: title,
      description: description,
      thumbnailUrl: '',
      category: category,
      ageRating: ageRating,
      developer: developer,
      indexFilePath: indexFilePath,
      thumbnailPath: thumbnailPath,
    );
  }
}
