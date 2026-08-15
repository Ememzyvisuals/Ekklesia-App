import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/isar_service.dart';
import 'bible_annotations_repository.dart';
import 'bible_audio_cache.dart';
import 'bible_importer.dart';
import 'bible_repository.dart';

/// Resolves to the single shared AppDatabase instance (see
/// AppDatabaseService in core/database/app_database.dart) — not disposed
/// here, since non-Riverpod singletons (VerseWorker, PrayerWorker, etc.)
/// share the same instance for their whole process lifetime.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  return AppDatabaseService.instance.database;
});

/// Isar is kept only for BibleAudioCacheEntity post-migration — see
/// isar_service.dart's header comment for why. Everything else that used
/// to read isarProvider now reads appDatabaseProvider instead.
final isarProvider = Provider<Isar>((ref) => IsarService.instance.isar);

final bibleRepositoryProvider = Provider<BibleRepository>((ref) {
  return BibleRepository(ref.watch(appDatabaseProvider));
});

final bibleImporterProvider = Provider<BibleImporter>((ref) {
  return BibleImporter(ref.watch(appDatabaseProvider));
});

final bibleAudioCacheProvider = Provider<BibleAudioCache>((ref) {
  return BibleAudioCache(ref.watch(isarProvider));
});

final bibleAnnotationsRepositoryProvider =
    Provider<BibleAnnotationsRepository>((ref) {
  return BibleAnnotationsRepository(ref.watch(appDatabaseProvider));
});

/// Bible dataset language codes ('en'/'yo'/'ha'/'ig'/'pcm') mapped from the
/// app's internal language keys used elsewhere (LanguageNotifier,
/// EkklesiaLanguage) — see AppConfig/app_settings_service.dart.
const Map<String, String> kAppLanguageToBibleCode = {
  'english': 'en',
  'yoruba': 'yo',
  'hausa': 'ha',
  'igbo': 'ig',
  'pidgin': 'pcm',
};

const Map<String, String> kBibleCodeLabel = {
  'en': 'English',
  'yo': 'Yoruba',
  'ha': 'Hausa',
  'ig': 'Igbo',
  'pcm': 'Nigerian Pidgin',
};

/// Which Bible language is currently selected for reading (independent of
/// the app's UI language — a Hausa-UI user can still read the English
/// Bible, and vice versa).
final bibleLanguageProvider = StateProvider<String>((ref) => 'en');

/// Re-checked whenever [bibleLanguageProvider] changes or invalidated after
/// an import completes.
final bibleImportStatusProvider =
    FutureProvider.autoDispose.family<bool, String>((ref, language) async {
  final repo = ref.watch(bibleRepositoryProvider);
  return repo.isLanguageImported(language);
});
