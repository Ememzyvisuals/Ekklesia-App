import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/shared/result.dart';
import '../domain/game_entry.dart';
import 'local_games_repository.dart';

/// Turns a user-picked `.zip` game bundle into a playable, fully offline
/// [GameEntry] — the local-import counterpart to the bundled
/// `assets/data/games.json` catalog (see GameEntry's doc comment).
///
/// Expected bundle shape (a self-contained HTML5 game, e.g. exported by
/// Construct/GDevelop/Phaser or hand-built):
///   my-game.zip
///     index.html          <- required, the entry point
///     manifest.json        <- optional: {"title","description","category","ageRating","developer"}
///     thumbnail.png|.jpg   <- optional, shown in the Games grid
///     (any other assets the game references by relative path)
///
/// Nothing here ever makes a network call — nothing runs but the zip the
/// user already has on their device, from wherever they got it.
class GameImportService {
  GameImportService._internal();
  static final GameImportService instance = GameImportService._internal();

  static const _uuid = Uuid();

  Future<Result<GameEntry>> pickAndImport() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        withData: false,
        withReadStream: false,
      );
      final path = picked?.files.single.path;
      if (path == null) {
        // User cancelled the picker — not an error.
        return const Result.failure(AppFailure(message: '', retryable: false));
      }
      final result = await importFromZipPath(path);
      return result;
    } catch (e) {
      return Result.failure(AppFailure(
        message: 'Could not open that file picker.',
        debugDetail: e.toString(),
      ));
    }
  }

  Future<Result<GameEntry>> importFromZipPath(String zipPath) async {
    final id = _uuid.v4();
    final gamesDir = await _localGamesRoot();
    final targetDir = Directory(p.join(gamesDir.path, id));

    try {
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // Guard against zip-slip: every entry must extract inside targetDir.
      await targetDir.create(recursive: true);
      for (final entry in archive) {
        final outPath = p.normalize(p.join(targetDir.path, entry.name));
        if (!p.isWithin(targetDir.path, outPath) && outPath != targetDir.path) {
          throw const FormatException(
              'This file contains an unsafe path and was rejected.');
        }
        if (entry.isFile) {
          final outFile = File(outPath);
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(entry.content as List<int>);
        } else {
          await Directory(outPath).create(recursive: true);
        }
      }

      final indexFile = await _findEntryPoint(targetDir);
      if (indexFile == null) {
        await targetDir.delete(recursive: true);
        return const Result.failure(AppFailure(
          message:
              'That .zip doesn\'t contain an index.html — it needs to be a '
              'packaged HTML5 game with an index.html entry point.',
          retryable: false,
        ));
      }

      final manifest = await _readManifest(targetDir);
      final thumbnailPath = await _findThumbnail(targetDir);
      final fallbackTitle = p.basenameWithoutExtension(zipPath);

      final title = (manifest?['title'] as String?)?.trim().isNotEmpty == true
          ? manifest!['title'] as String
          : fallbackTitle;
      final description = manifest?['description'] as String? ?? '';
      final category = manifest?['category'] as String? ?? 'Imported';
      final ageRating = manifest?['ageRating'] as String? ?? 'All ages';
      final developer = manifest?['developer'] as String? ?? 'You';

      await LocalGamesRepository.instance.insert(
        id: id,
        title: title,
        description: description,
        category: category,
        ageRating: ageRating,
        developer: developer,
        indexFilePath: indexFile.path,
        thumbnailPath: thumbnailPath?.path,
      );

      return Result.success(GameEntry.fromLocalRow(
        id: id,
        title: title,
        description: description,
        category: category,
        ageRating: ageRating,
        developer: developer,
        indexFilePath: indexFile.path,
        thumbnailPath: thumbnailPath?.path,
      ));
    } catch (e) {
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
      }
      return Result.failure(AppFailure(
        message: 'Could not import that game — the .zip may be corrupted '
            'or not a valid game bundle.',
        debugDetail: e.toString(),
      ));
    }
  }

  /// Deletes both the DB row and the extracted files on disk. Call this,
  /// never LocalGamesRepository.deleteRow directly, from UI code — see
  /// that method's doc comment for why the split exists.
  Future<void> deleteImportedGame(GameEntry game) async {
    if (!game.isLocal) return;
    await LocalGamesRepository.instance.deleteRow(game.id);
    // indexFilePath is always <local_games_root>/<id>/(subfolder.../)
    // index.html — [game.id] alone gives us the whole extracted
    // directory to remove, regardless of how deep index.html sat inside
    // the zip's own internal folder structure.
    final gamesRoot = await _localGamesRoot();
    final gameDir = Directory(p.join(gamesRoot.path, game.id));
    if (await gameDir.exists()) {
      await gameDir.delete(recursive: true);
    }
  }

  Future<Directory> _localGamesRoot() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'local_games'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Searches for `index.html` anywhere in the extracted bundle, since
  /// some exporters (Construct, GDevelop) nest it inside a subfolder
  /// rather than the zip root. Prefers the shallowest match.
  Future<File?> _findEntryPoint(Directory root) async {
    File? best;
    var bestDepth = 1 << 30;
    await for (final entity in root.list(recursive: true)) {
      if (entity is File &&
          p.basename(entity.path).toLowerCase() == 'index.html') {
        final depth = p.split(p.relative(entity.path, from: root.path)).length;
        if (depth < bestDepth) {
          best = entity;
          bestDepth = depth;
        }
      }
    }
    return best;
  }

  Future<Map<String, dynamic>?> _readManifest(Directory root) async {
    final file = File(p.join(root.path, 'manifest.json'));
    if (!await file.exists()) return null;
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<File?> _findThumbnail(Directory root) async {
    for (final name in [
      'thumbnail.png',
      'thumbnail.jpg',
      'thumbnail.jpeg',
    ]) {
      final file = File(p.join(root.path, name));
      if (await file.exists()) return file;
    }
    return null;
  }
}
