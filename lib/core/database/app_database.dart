import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';
import 'package:sqlite3/sqlite3.dart';

part 'app_database.g.dart';

// ---------------------------------------------------------------------------
// Phase 1 of PROJECT_MIGRATION_AUDIT.md: local-first DB foundation.
//
// This table set covers everything that was split across Isar (Bible only)
// and Firestore (bookmarks/highlights/notes/reading-progress/streak,
// plus the Firebase Auth user doc) in V1. It does NOT yet cover
// YouTube cache, downloads, or AI conversations — those stay on their
// current backend until their own migration phase, so this file doesn't
// pretend to be a full port in one shot.
//
// bible_books / bible_chapters / bible_verses / bible_import_records are a
// direct field-for-field port of BibleBookEntity / BibleChapterEntity /
// BibleVerseEntity / BibleImportRecordEntity from
// features/bible/data/bible_local_schema.dart, so BibleImporter's output
// shape doesn't need to change — only where it writes to.
//
// bookmarks / highlights / notes / reading_progress / reading_streak are a
// direct port of the Firestore-backed collections used today by
// bookmark_repository.dart and the not-yet-created
// bible_annotations_repository.dart Drift equivalent.
//
// local_profiles replaces the Firebase Auth user + Firestore user doc.
// This table alone does not remove Firebase Auth from the app — see
// PROJECT_MIGRATION_AUDIT.md §3 on the Groq-proxy auth dependency that has
// to be resolved first. Writing this table is necessary-but-not-sufficient
// for Phase 2.
//
// NOTE ON BUILD STATE: this file requires `dart run build_runner build` to
// generate app_database.g.dart before it will compile. No Dart/Flutter SDK
// is available in the environment this was written in, so the generated
// file does not exist yet and this has not been compiled or run. Treat the
// table definitions below as reviewed-by-reading, not verified-by-build.
// ---------------------------------------------------------------------------

class BibleBooks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get language => text()();
  TextColumn get code => text()(); // canonical 3-letter code, e.g. 'GEN'
  TextColumn get name => text()();
  TextColumn get testament => text()(); // 'OT' or 'NT'
  IntColumn get position => integer()();
  IntColumn get chapterCount => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {language, code},
      ];
}

class BibleChapters extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get language => text()();
  TextColumn get bookCode => text()();
  IntColumn get number => integer()();
  IntColumn get verseCount => integer()();
  TextColumn get localTitle => text().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {language, bookCode, number},
      ];
}

class BibleVerses extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get language => text()();
  TextColumn get bookCode => text()();
  IntColumn get chapter => integer()();
  IntColumn get number => integer()();
  TextColumn get content => text().nullable()();
  BoolColumn get omitted => boolean().withDefault(const Constant(false))();
  BoolColumn get approximate => boolean().withDefault(const Constant(false))();
  TextColumn get normalizedText => text().withDefault(const Constant(''))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {language, bookCode, chapter, number},
      ];
}

class BibleImportRecords extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get language => text().unique()();
  TextColumn get checksum => text()();
  IntColumn get booksImported => integer()();
  IntColumn get chaptersImported => integer()();
  IntColumn get versesImported => integer()();
  IntColumn get approximateVerseCount => integer()();
  IntColumn get omittedVerseCount => integer()();
  DateTimeColumn get importedAt => dateTime()();
}

/// Generalized to match BookmarkItem's domain shape (bible / sermon /
/// aiConversation — see bookmark_item.dart), not Bible-only. The V1
/// Firestore doc was keyed by uid+type+refId to support multiple synced
/// accounts on the same collection; local-first has exactly one user, so
/// [id] alone (type+refId, no uid) is the unique key here.
class Bookmarks extends Table {
  TextColumn get id => text()(); // BookmarkItem.deterministicId minus uid
  TextColumn get type => text()(); // BookmarkType.wireName
  TextColumn get refId => text()();
  TextColumn get title => text()();
  TextColumn get subtitle => text().withDefault(const Constant(''))();
  TextColumn get language =>
      text().nullable()(); // only meaningful for type == 'bible'
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class Highlights extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get language => text()();
  TextColumn get bookCode => text()();
  IntColumn get chapter => integer()();
  IntColumn get verseNumber => integer()();
  TextColumn get colorHex => text()(); // ARGB hex, e.g. 'FFFFEB3B'
  DateTimeColumn get createdAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {language, bookCode, chapter, verseNumber},
      ];
}

class Notes extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get language => text()();
  TextColumn get bookCode => text()();
  IntColumn get chapter => integer()();
  IntColumn get verseNumber => integer()();
  TextColumn get content => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {language, bookCode, chapter, verseNumber},
      ];
}

/// Local cache of DCLM's YouTube uploads — replaces the Firestore
/// `youtube_videos` collection the `youtube-sync` Cloudflare Worker used
/// to write to (PROJECT_MIGRATION_AUDIT.md Phase 3: the client now calls
/// the YouTube Data API v3 directly with a restricted, public API key —
/// see AppConfig.youtubeApiKey and youtube_repository.dart — instead of
/// proxying through a Worker that held it server-side. Same "cache
/// locally, refresh on a timer, never block on network" shape, just
/// backed by Drift instead of a Firestore SDK's own offline cache.
class YoutubeVideos extends Table {
  TextColumn get videoId => text()();
  TextColumn get title => text()();
  TextColumn get description => text()();
  TextColumn get thumbnailUrl => text()();
  DateTimeColumn get publishedAt => dateTime()();
  TextColumn get channelTitle => text()();
  IntColumn get durationSeconds => integer().nullable()();
  TextColumn get liveStatus =>
      text().withDefault(const Constant('none'))(); // 'none'|'live'|'upcoming'
  TextColumn get category => text().nullable()();
  TextColumn get aiOverviewJson => text()
      .nullable()(); // cached MessageOverview, see message_overview_service.dart

  @override
  Set<Column> get primaryKey => {videoId};
}

/// Single-row sentinel table (id always 1) mirroring the old
/// `config/youtube_live_status` Firestore doc — whichever upload is
/// currently live, if any.
class YoutubeLiveStatus extends Table {
  IntColumn get id => integer()();
  TextColumn get videoId => text().nullable()();
  TextColumn get title => text().nullable()();
  TextColumn get liveStatus => text().withDefault(const Constant('none'))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Local notification history — replaces the Firestore `notifications`
/// collection (PROJECT_MIGRATION_AUDIT.md Phase 4: spec §33, "local
/// notifications only, no FCM"). Written by notification_service.dart
/// whenever a local notification fires or a reminder is scheduled, read
/// by notification_worker.dart for the in-app notification center list.
class AppNotifications extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  TextColumn get body => text()();
  TextColumn get type => text()
      .withDefault(const Constant('other'))(); // maps to NotificationCategory
  BoolColumn get read => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
}

/// One row per reminder type (daily verse, prayer, reading) — spec §33's
/// "Daily verse reminder, Prayer reminder, Reading reminder" scheduled
/// locally, with a user-controlled enable/hour/minute per reminder
/// rather than a fixed global schedule.
class NotificationSchedules extends Table {
  TextColumn get reminderType => text()(); // 'daily_verse'|'prayer'|'reading'
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get hour => integer().withDefault(const Constant(8))();
  IntColumn get minute => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {reminderType};
}

/// Local AI conversation history — replaces the Firestore `ai_conversations`
/// collection (PROJECT_MIGRATION_AUDIT.md Phase 4: found while auditing
/// `firestore.rules` that every remaining Firestore collection gated on
/// `request.auth != null`, which can never be true again post-Phase-2 —
/// this collection specifically held private per-user chat text with no
/// way left to prove which device a doc belonged to, since Firestore
/// rules have no visibility into the Cloudflare-Worker-verified device
/// token scheme. That's a real security regression, not a cosmetic gap,
/// so it's fixed by migration rather than by loosening the rule.
class AiConversations extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get role => text()(); // 'user'|'assistant'
  TextColumn get content => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Impact Academy archived messages (sermon/teaching transcripts +
/// metadata) — replaces the Firestore `messages` collection. Seeded
/// once from the bundled `assets/data/messages.json` catalog on first
/// launch (see MessageRepository._ensureSeeded), then lives entirely in
/// this table from then on: [summary]/[quiz] are filled in lazily (first
/// Groq request, cached here so repeat visits don't re-call the API) the
/// same way the Firestore doc used to be updated in place.
///
/// Optional content updates (new/edited messages an admin wants to push
/// without a full app release) go through MessageRepository.syncFromUrl,
/// which upserts rows from a static JSON file the user explicitly
/// chooses to check for — never automatic, matching the app's
/// "online only when asked" pattern for Radio/AI chat.
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get category => text()();
  TextColumn get transcript => text()();
  TextColumn get summary => text().nullable()();
  // JSON-encoded List<Map<String, dynamic>> — quiz questions/answers.
  TextColumn get quiz => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Locally recorded quiz attempts (score, message, timestamp) — replaces
/// the Firestore `quiz_progress` collection (PROJECT_MIGRATION_AUDIT.md
/// Phase 4: found in the same audit pass as AiConversations — another
/// per-user Firestore collection with no way left to prove device
/// identity to Firestore rules post-Phase-2).
class QuizAttempts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get messageId => text()();
  IntColumn get score => integer()();
  IntColumn get totalQuestions => integer()();
  DateTimeColumn get completedAt => dateTime()();
}

/// Tracks each on-device TTS language model's install state — spec §45's
/// ModelRegistry, backed by Drift instead of an in-memory map so status
/// survives app restarts (a half-downloaded model shouldn't look
/// "ready" just because the process restarted mid-download).
/// PROJECT_MIGRATION_AUDIT.md Phase 5. One row per language; see
/// tts_model_registry.dart for the actual download/lifecycle logic —
/// this table is just the persisted state.
class TtsModelStatus extends Table {
  TextColumn get language =>
      text()(); // 'yor'|'hau'|'pcm' — MMS codes, see LocalTtsEngine
  TextColumn get status =>
      text().withDefault(const Constant('not_installed'))();
  // 'not_installed'|'downloading'|'ready'|'error' — spec §45's exact list
  TextColumn get localModelPath => text().nullable()();
  TextColumn get localTokensPath => text().nullable()();
  IntColumn get sampleRate => integer().nullable()();
  TextColumn get errorMessage => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {language};
}

class ReadingProgress extends Table {
  TextColumn get language => text()();
  TextColumn get bookCode => text()();
  TextColumn get bookName => text()();
  IntColumn get chapter => integer()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {language};
}

class ReadingStreak extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get currentStreak => integer().withDefault(const Constant(0))();
  IntColumn get longestStreak => integer().withDefault(const Constant(0))();
  IntColumn get totalDaysRead => integer().withDefault(const Constant(0))();
  IntColumn get lastReadDay => integer().withDefault(const Constant(0))();
}

/// Replaces the Firebase Auth user + Firestore user doc. Single-row table
/// in practice (this app has one local user, not a synced account) — kept
/// as a table rather than a settings key so it has real columns/types and
/// can gain rows later if multi-profile ever becomes a real requirement.
class LocalProfiles extends Table {
  TextColumn get id => text()(); // generated once, stored, never re-derived
  TextColumn get displayName => text()();
  TextColumn get ageGroup => text()();
  TextColumn get gender => text()();
  TextColumn get preferredLanguage => text()();
  TextColumn get avatarId => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// User-imported offline games — a game the user picked as a packaged
/// `.zip` (HTML/JS/CSS bundle with an `index.html` entry point), which
/// GameImportService extracted onto local disk. Wholly separate from the
/// bundled `assets/data/games.json` catalog (developer-curated, launch/
/// embed URL only): this table is device-local, user-controlled, and
/// requires no network at all to install or play — the .zip travels
/// however the user got it onto the phone (downloaded, AirDropped,
/// copied via USB, etc.), and once imported nothing here ever calls out
/// to the internet again.
class LocalGames extends Table {
  TextColumn get id => text()(); // uuid, generated at import time
  TextColumn get title => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
  TextColumn get category => text().withDefault(const Constant('Imported'))();
  TextColumn get ageRating => text().withDefault(const Constant('All ages'))();
  TextColumn get developer => text().withDefault(const Constant('You'))();
  // Absolute path to the extracted bundle's index.html — passed straight
  // to WebViewController.loadFile, so this is always a real file:// path
  // on this device, never a URL.
  TextColumn get indexFilePath => text()();
  // Absolute path to a local thumbnail image extracted from the bundle
  // (thumbnail.png/.jpg at the zip root), if the bundle included one.
  TextColumn get thumbnailPath => text().nullable()();
  DateTimeColumn get importedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// A game added by pasting a URL directly in-app, rather than via the
/// bundled developer-curated catalog (assets/data/games.json, requires
/// a new app build to change) or a zip import (fully offline). This is
/// the "bring back the ability to add a game by link" request — the app
/// itself never fetches or vets these URLs beyond basic format
/// validation; whatever's at the URL loads directly in a WebView
/// exactly like a catalog entry's embedUrl does, so it needs a live
/// internet connection to play, unlike LocalGames.
class UserAddedGames extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get url => text()();
  DateTimeColumn get addedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [
  BibleBooks,
  BibleChapters,
  BibleVerses,
  BibleImportRecords,
  Bookmarks,
  Highlights,
  Notes,
  ReadingProgress,
  ReadingStreak,
  LocalProfiles,
  YoutubeVideos,
  YoutubeLiveStatus,
  AppNotifications,
  NotificationSchedules,
  AiConversations,
  QuizAttempts,
  TtsModelStatus,
  Messages,
  LocalGames,
  UserAddedGames,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // v1 -> v2: added LocalGames (offline-imported game bundles).
          // Every other table is untouched — additive only, no existing
          // user data (bookmarks, notes, Bible progress, etc.) is at risk.
          //
          // Each check below also falls back to actually looking for the
          // table on disk (not just trusting `from`) — a real,
          // reproducible failure mode found while investigating "added
          // games don't show up": if any earlier build's `schemaVersion`
          // ever got bumped without its matching `createTable` call
          // actually shipping (or a person's install history otherwise
          // left `schemaVersion` ahead of what tables really exist), a
          // pure `from < N` check silently never runs again on later
          // upgrades — Drift only invokes onUpgrade when the stored
          // version is strictly less than the current one, so it has no
          // other way to notice a table is still missing. Every insert
          // into that table then fails with a real "no such table" error
          // that nothing was catching, which from the person's side just
          // looks like "I added it and nothing happened."
          if (from < 2 || !await _tableExists('local_games')) {
            await m.createTable(localGames);
          }
          // v2 -> v3: added UserAddedGames (URL-added games) — same
          // additive-only guarantee, same self-healing fallback.
          if (from < 3 || !await _tableExists('user_added_games')) {
            await m.createTable(userAddedGames);
          }
        },
      );

  Future<bool> _tableExists(String name) async {
    final row = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(name)],
    ).getSingleOrNull();
    return row != null;
  }
}

/// Plain singleton accessor, mirroring IsarService's pattern — used by
/// non-Riverpod call sites (VerseWorker, PrayerWorker, ProgramWorker, and
/// any other core/services/*_worker.dart that ran outside the widget
/// tree and previously did `BibleRepository(IsarService.instance.isar)`).
/// Riverpod widgets should use appDatabaseProvider
/// (features/bible/data/bible_providers.dart) instead of this directly —
/// both resolve to the same single AppDatabase instance either way, since
/// AppDatabase's constructor opens a LazyDatabase and this class only
/// ever constructs one.
class AppDatabaseService {
  AppDatabaseService._internal();
  static final AppDatabaseService instance = AppDatabaseService._internal();

  AppDatabase? _db;

  AppDatabase get database => _db ??= AppDatabase();
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'ekklesia.sqlite'));
    // Required on Android for sqlite3_flutter_libs to locate the bundled
    // native library before opening the database.
    if (Platform.isAndroid) {
      await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
    }
    final cachebase = (await getTemporaryDirectory()).path;
    sqlite3.tempDirectory = cachebase;
    return NativeDatabase.createInBackground(file);
  });
}
