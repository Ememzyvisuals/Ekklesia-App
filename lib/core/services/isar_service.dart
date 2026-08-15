import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/bible/data/bible_audio_cache_schema.dart';

/// Opens and owns the single shared Isar instance for the app.
///
/// Post-Phase-1 (PROJECT_MIGRATION_AUDIT.md): Bible verses/books/chapters,
/// highlights, notes, and reading progress/streak have all moved to Drift
/// (see core/database/app_database.dart). Isar is kept ONLY for
/// BibleAudioCacheEntity — the cached-audio metadata table wasn't part of
/// this migration pass (it's TTS-cache plumbing that Phase 5's on-device
/// TTS rework will replace wholesale, so porting it to Drift now would be
/// throwaway work). Once Phase 5 lands, this file and the
/// `isar_community` / `isar_community_flutter_libs` pubspec entries can
/// come out entirely. (Renamed from `isar`/`isar_flutter_libs` — upstream
/// isar is unmaintained and permanently capped analyzer <6.0.0, which
/// couldn't coexist with drift_dev; isar_community is the maintained fork
/// with the same API.)
class IsarService {
  IsarService._internal();
  static final IsarService instance = IsarService._internal();

  Isar? _isar;

  /// Must be awaited once in main() before runApp(). Safe to call more than
  /// once (idempotent) — Isar.open with the same schema/name is a no-op if
  /// already open in this isolate.
  Future<Isar> open() async {
    if (_isar != null) return _isar!;
    final dir = await getApplicationDocumentsDirectory();
    _isar = await Isar.open(
      [
        BibleAudioCacheEntitySchema,
      ],
      directory: dir.path,
      name: 'ekklesia',
    );
    return _isar!;
  }

  /// Throws if [open] hasn't completed yet — call sites should only run
  /// after main()'s startup sequence.
  Isar get isar {
    final instance = _isar;
    if (instance == null) {
      throw StateError(
          'IsarService.open() must be awaited in main() before use.');
    }
    return instance;
  }
}
