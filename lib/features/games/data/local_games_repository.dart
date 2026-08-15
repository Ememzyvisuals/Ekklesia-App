import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/game_entry.dart';

/// Drift-backed CRUD for user-imported offline games (see LocalGames
/// table in app_database.dart and GameImportService for how a .zip
/// becomes a row here). Mirrors MessageRepository's plain-singleton
/// pattern used by non-Riverpod call sites.
class LocalGamesRepository {
  LocalGamesRepository._internal();
  static final LocalGamesRepository instance = LocalGamesRepository._internal();

  AppDatabase get _db => AppDatabaseService.instance.database;

  Future<List<GameEntry>> getAll() async {
    final rows = await (_db.select(_db.localGames)
          ..orderBy([(t) => OrderingTerm.desc(t.importedAt)]))
        .get();
    return rows
        .map((row) => GameEntry.fromLocalRow(
              id: row.id,
              title: row.title,
              description: row.description,
              category: row.category,
              ageRating: row.ageRating,
              developer: row.developer,
              indexFilePath: row.indexFilePath,
              thumbnailPath: row.thumbnailPath,
            ))
        .toList();
  }

  Future<void> insert({
    required String id,
    required String title,
    required String description,
    required String category,
    required String ageRating,
    required String developer,
    required String indexFilePath,
    String? thumbnailPath,
  }) {
    return _db.into(_db.localGames).insert(LocalGamesCompanion.insert(
          id: id,
          title: title,
          description: Value(description),
          category: Value(category),
          ageRating: Value(ageRating),
          developer: Value(developer),
          indexFilePath: indexFilePath,
          thumbnailPath: Value(thumbnailPath),
          importedAt: DateTime.now(),
        ));
  }

  /// Removes the DB row only. The caller (GameImportService) is
  /// responsible for deleting the extracted files on disk — kept
  /// separate so a repository-level delete never silently leaves an
  /// orphaned directory or, worse, deletes the wrong thing on a partial
  /// failure.
  Future<void> deleteRow(String id) {
    return (_db.delete(_db.localGames)..where((t) => t.id.equals(id))).go();
  }

  Future<GameEntry?> getById(String id) async {
    final row = await (_db.select(_db.localGames)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return GameEntry.fromLocalRow(
      id: row.id,
      title: row.title,
      description: row.description,
      category: row.category,
      ageRating: row.ageRating,
      developer: row.developer,
      indexFilePath: row.indexFilePath,
      thumbnailPath: row.thumbnailPath,
    );
  }
}
