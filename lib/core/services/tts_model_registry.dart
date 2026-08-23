import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../database/app_database.dart';

enum TtsModelDownloadStatus { notInstalled, downloading, ready, error }

class TtsModelInfo {
  const TtsModelInfo({
    required this.language,
    required this.status,
    this.localModelPath,
    this.localTokensPath,
    this.sampleRate,
    this.errorMessage,
    this.downloadProgress,
  });

  final String language; // MMS code, e.g. 'yor'
  final TtsModelDownloadStatus status;
  final String? localModelPath;
  final String? localTokensPath;
  final int? sampleRate;
  final String? errorMessage;

  /// 0.0-1.0 while [status] is downloading; null otherwise.
  final double? downloadProgress;

  bool get isReady => status == TtsModelDownloadStatus.ready;
}

/// Spec §45's ModelRegistry + ModelLoader combined: tracks install state
/// (persisted via Drift's `TtsModelStatus` table) and does the actual
/// download from `Axiveri/Renpiper-mms-onnx-V1`
/// (Renpiper-mms-onnx-V1_build_and_publish.ipynb).
///
/// Models download on demand — never bundled in the APK (spec §16's
/// "models must be stored efficiently, do not duplicate unnecessarily";
/// bundling all 3 available languages would add real MB to every
/// install regardless of which languages a given user actually reads
/// in). Stored under the app's documents directory so they survive app
/// updates but get cleared on uninstall, same as everything else
/// user-controlled in this app.
class TtsModelRegistry {
  TtsModelRegistry._internal();
  static final TtsModelRegistry instance = TtsModelRegistry._internal();

  final Dio _dio = Dio();

  AppDatabase get _db => AppDatabaseService.instance.database;

  Future<Directory> _modelDir(String mmsCode) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docsDir.path, 'tts_models', mmsCode));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<TtsModelInfo> status(String mmsCode) async {
    final row = await (_db.select(_db.ttsModelStatus)
          ..where((t) => t.language.equals(mmsCode)))
        .getSingleOrNull();
    if (row == null) {
      return TtsModelInfo(
          language: mmsCode, status: TtsModelDownloadStatus.notInstalled);
    }
    return TtsModelInfo(
      language: mmsCode,
      status: _parseStatus(row.status),
      localModelPath: row.localModelPath,
      localTokensPath: row.localTokensPath,
      sampleRate: row.sampleRate,
      errorMessage: row.errorMessage,
    );
  }

  /// Downloads model.onnx + tokens.txt for [mmsCode] if not already
  /// present, emitting progress. No-ops (emits the current ready state
  /// once) if the model is already downloaded and its files still exist
  /// on disk — re-checks the filesystem rather than trusting the DB row
  /// blindly, in case the app's storage was cleared externally.
  Stream<TtsModelInfo> ensureDownloaded(String mmsCode) {
    if (!AppConfig.mmsOnnxAvailableLanguages.contains(mmsCode)) {
      return Stream.value(TtsModelInfo(
        language: mmsCode,
        status: TtsModelDownloadStatus.error,
        errorMessage:
            'No on-device model exists for "$mmsCode". See AppConfig\'s '
            'mmsOnnxAvailableLanguages doc comment for what was actually '
            'confirmed available.',
      ));
    }

    final controller = StreamController<TtsModelInfo>();
    unawaited(_download(mmsCode, controller));
    return controller.stream;
  }

  Future<void> _download(
      String mmsCode, StreamController<TtsModelInfo> controller) async {
    try {
      final dir = await _modelDir(mmsCode);
      final modelPath = p.join(dir.path, 'model.onnx');
      final tokensPath = p.join(dir.path, 'tokens.txt');

      final modelFile = File(modelPath);
      final tokensFile = File(tokensPath);
      if (await modelFile.exists() &&
          await tokensFile.exists() &&
          await modelFile.length() > 0) {
        final ready = TtsModelInfo(
          language: mmsCode,
          status: TtsModelDownloadStatus.ready,
          localModelPath: modelPath,
          localTokensPath: tokensPath,
        );
        await _persist(ready);
        controller.add(ready);
        await controller.close();
        return;
      }

      await _persist(TtsModelInfo(
          language: mmsCode, status: TtsModelDownloadStatus.downloading));
      controller.add(TtsModelInfo(
          language: mmsCode,
          status: TtsModelDownloadStatus.downloading,
          downloadProgress: 0));

      // Downloaded to `.part` temp files first, renamed to their real
      // names only once each download fully completes — real bug found
      // here: the old version downloaded straight to `tokensPath`/
      // `modelPath`, so an interrupted download (connection drop, app
      // killed mid-download, storage full partway through) left a
      // partial file sitting at the exact path the "already downloaded?"
      // check above looks for. That check only verifies the file exists
      // and has non-zero length — a partial file satisfies both — so a
      // failed download could get silently treated as "ready" on the
      // next app open, then fail with a confusing "Could not generate
      // audio" the moment playback actually tried to load it, with the
      // download picker never getting another chance to show an error
      // or a Retry button. Renaming only on success means a partial
      // download can never occupy the final path.
      final tokensPart = '$tokensPath.part';
      final modelPart = '$modelPath.part';

      // tokens.txt first — tiny, and if this 404s (a language wrongly
      // marked available) we fail fast before downloading the much
      // larger model.onnx for nothing.
      await _dio.download(
        '${AppConfig.mmsOnnxRepoBaseUrl}/$mmsCode/tokens.txt',
        tokensPart,
      );
      await File(tokensPart).rename(tokensPath);

      await _dio.download(
        '${AppConfig.mmsOnnxRepoBaseUrl}/$mmsCode/model.onnx',
        modelPart,
        onReceiveProgress: (received, total) {
          if (total <= 0) return;
          controller.add(TtsModelInfo(
            language: mmsCode,
            status: TtsModelDownloadStatus.downloading,
            downloadProgress: received / total,
          ));
        },
      );
      await File(modelPart).rename(modelPath);

      final ready = TtsModelInfo(
        language: mmsCode,
        status: TtsModelDownloadStatus.ready,
        localModelPath: modelPath,
        localTokensPath: tokensPath,
      );
      await _persist(ready);
      controller.add(ready);
    } catch (e) {
      // Clean up any leftover `.part` file from this failed attempt so a
      // retry starts from a clean slate rather than potentially finding
      // a stray partial file confusing a future run.
      final dir = await _modelDir(mmsCode);
      for (final name in ['model.onnx.part', 'tokens.txt.part']) {
        final leftover = File(p.join(dir.path, name));
        if (await leftover.exists()) {
          await leftover.delete();
        }
      }
      final failed = TtsModelInfo(
        language: mmsCode,
        status: TtsModelDownloadStatus.error,
        errorMessage: e.toString(),
      );
      await _persist(failed);
      controller.add(failed);
    } finally {
      await controller.close();
    }
  }

  Future<void> _persist(TtsModelInfo info) {
    return _db.into(_db.ttsModelStatus).insertOnConflictUpdate(
          TtsModelStatusCompanion.insert(
            language: info.language,
            status: Value(_statusWire(info.status)),
            localModelPath: Value(info.localModelPath),
            localTokensPath: Value(info.localTokensPath),
            sampleRate: Value(info.sampleRate),
            errorMessage: Value(info.errorMessage),
            updatedAt: DateTime.now(),
          ),
        );
  }

  /// Deletes a downloaded model's files and resets its status — exposed
  /// for a future Settings "manage downloaded voices" screen (not built
  /// this pass; storage-management UI is a separate, smaller piece).
  Future<void> remove(String mmsCode) async {
    final dir = await _modelDir(mmsCode);
    if (await dir.exists()) await dir.delete(recursive: true);
    await (_db.delete(_db.ttsModelStatus)
          ..where((t) => t.language.equals(mmsCode)))
        .go();
  }

  TtsModelDownloadStatus _parseStatus(String wire) => switch (wire) {
        'downloading' => TtsModelDownloadStatus.downloading,
        'ready' => TtsModelDownloadStatus.ready,
        'error' => TtsModelDownloadStatus.error,
        _ => TtsModelDownloadStatus.notInstalled,
      };

  String _statusWire(TtsModelDownloadStatus status) => switch (status) {
        TtsModelDownloadStatus.notInstalled => 'not_installed',
        TtsModelDownloadStatus.downloading => 'downloading',
        TtsModelDownloadStatus.ready => 'ready',
        TtsModelDownloadStatus.error => 'error',
      };
}
