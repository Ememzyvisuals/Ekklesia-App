import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../domain/game_entry.dart';

/// CRUD for games added by pasting a URL directly in-app — see
/// UserAddedGames' doc comment in app_database.dart for how this
/// differs from the bundled catalog and from zip-imported LocalGames.
class UserAddedGamesRepository {
  UserAddedGamesRepository._internal();
  static final UserAddedGamesRepository instance =
      UserAddedGamesRepository._internal();

  static const _uuid = Uuid();

  AppDatabase get _db => AppDatabaseService.instance.database;

  Future<List<GameEntry>> getAll() async {
    final rows = await (_db.select(_db.userAddedGames)
          ..orderBy([(t) => OrderingTerm.desc(t.addedAt)]))
        .get();
    return rows
        .map((row) => GameEntry(
              id: row.id,
              title: row.title,
              description: '',
              thumbnailUrl: '',
              category: 'Added by link',
              ageRating: 'All ages',
              developer: 'You',
              // Routed through embedUrl so it plays in the app's own
              // WebView (see games_screen.dart's _openGame), same as a
              // catalog entry the publisher has approved for embedding
              // — the person adding their own link is implicitly
              // approving that for themselves.
              embedUrl: row.url,
              isUserAdded: true,
            ))
        .toList();
  }

  Future<void> insert({required String title, required String url}) {
    return _db.into(_db.userAddedGames).insert(UserAddedGamesCompanion.insert(
          id: _uuid.v4(),
          title: title,
          url: url,
          addedAt: DateTime.now(),
        ));
  }

  Future<void> delete(String id) {
    return (_db.delete(_db.userAddedGames)..where((t) => t.id.equals(id))).go();
  }
}
