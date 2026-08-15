import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../../../core/shared/result.dart';
import '../domain/game_entry.dart';

/// Reads the curated (online) Games catalog bundled at
/// `assets/data/games.json` — no remote collection, no mock fallback
/// (see GameEntry's doc comment for why an automated catalog source
/// doesn't exist). The catalog is simply an empty JSON array (`[]`)
/// until entries are added by hand, so adding a game here means editing
/// that file and shipping a new build. This is the *online* half of the
/// Games feature only — user-imported offline bundles are a separate
/// source entirely; see LocalGamesRepository / GameImportService.
class GamesRepository {
  const GamesRepository({this.assetPath = 'assets/data/games.json'});

  final String assetPath;

  Future<Result<List<GameEntry>>> fetchCatalog() async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      final decoded = jsonDecode(raw) as List<dynamic>;
      final entries = decoded
          .map((e) => GameEntry.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.title.compareTo(b.title));

      return Result.success(entries);
    } catch (e) {
      return Result.failure(AppFailure(
        message: 'Something went wrong loading Games.',
        debugDetail: e.toString(),
      ));
    }
  }
}
