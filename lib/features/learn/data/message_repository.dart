import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import '../../../core/database/app_database.dart';

/// A single archived message (sermon/teaching) shown in Impact Academy.
///
/// Local-first: seeded once from the bundled `assets/data/messages.json`
/// catalog (admin-curated, not user-generated) into the Drift `Messages`
/// table on first launch, then read/written entirely from there —
/// summary/quiz are generated on first request and cached back onto the
/// same row so repeat visits don't re-call Groq unnecessarily. No
/// Firestore, no server required for the app to function.
///
/// Content updates (new/edited messages) ship two ways:
/// 1. A new app build with an updated `assets/data/messages.json` — the
///    default, fully offline path.
/// 2. [MessageRepository.syncFromUrl], which fetches a JSON file the
///    user explicitly points it at and upserts rows from it — opt-in,
///    on-demand, same "online only when the user asks" pattern as Radio
///    and AI chat. Never runs automatically.
class ArchivedMessage {
  ArchivedMessage({
    required this.id,
    required this.title,
    required this.category,
    required this.transcript,
    this.summary,
    this.quiz,
  });

  final String id;
  final String title;
  final String
      category; // Sunday Service | Bible Study | GCK | Programs | Impact Academy
  final String transcript;
  final String? summary;
  final List<Map<String, dynamic>>? quiz;

  factory ArchivedMessage.fromRow(Message row) {
    return ArchivedMessage(
      id: row.id,
      title: row.title,
      category: row.category,
      transcript: row.transcript,
      summary: row.summary,
      quiz: row.quiz == null
          ? null
          : (jsonDecode(row.quiz!) as List<dynamic>)
              .cast<Map<String, dynamic>>(),
    );
  }

  factory ArchivedMessage.fromJson(Map<String, dynamic> data) {
    return ArchivedMessage(
      id: data['id'] as String,
      title: data['title'] as String? ?? 'Untitled',
      category: data['category'] as String? ?? 'Programs',
      transcript: data['transcript'] as String? ?? '',
      summary: data['summary'] as String?,
      quiz: (data['quiz'] as List<dynamic>?)?.cast<Map<String, dynamic>>(),
    );
  }
}

class MessageRepository {
  MessageRepository._internal();
  static final MessageRepository instance = MessageRepository._internal();

  static const _assetPath = 'assets/data/messages.json';

  AppDatabase get _db => AppDatabaseService.instance.database;

  bool _seeded = false;

  /// Populates the Messages table from the bundled asset the first time
  /// it's empty. Safe to call repeatedly — no-ops once seeded, and never
  /// overwrites rows that already exist (so locally-cached
  /// summary/quiz data, or rows added by syncFromUrl, are never
  /// clobbered by the bundled defaults on a later app launch).
  Future<void> _ensureSeeded() async {
    if (_seeded) return;
    _seeded = true;
    final existingCount = await (_db.selectOnly(_db.messages)
          ..addColumns([_db.messages.id.count()]))
        .map((row) => row.read(_db.messages.id.count()))
        .getSingleOrNull();
    if ((existingCount ?? 0) > 0) return;

    try {
      final raw = await rootBundle.loadString(_assetPath);
      final decoded = jsonDecode(raw) as List<dynamic>;
      final messages = decoded
          .map((e) => ArchivedMessage.fromJson(e as Map<String, dynamic>))
          .toList();
      await _db.batch((batch) {
        batch.insertAll(
          _db.messages,
          messages.map((m) => MessagesCompanion.insert(
                id: m.id,
                title: m.title,
                category: m.category,
                transcript: m.transcript,
                summary: Value(m.summary),
                quiz: Value(m.quiz == null ? null : jsonEncode(m.quiz)),
                updatedAt: DateTime.now(),
              )),
          mode: InsertMode.insertOrIgnore,
        );
      });
    } catch (_) {
      // Missing/malformed bundled asset — fail open with an empty
      // catalog rather than crashing Impact Academy.
    }
  }

  Future<List<ArchivedMessage>> getByCategory(String category) async {
    await _ensureSeeded();
    final rows = await (_db.select(_db.messages)
          ..where((t) => t.category.equals(category))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
    return rows.map(ArchivedMessage.fromRow).toList();
  }

  Future<void> saveSummary(String messageId, String summary) {
    return (_db.update(_db.messages)..where((t) => t.id.equals(messageId)))
        .write(MessagesCompanion(
      summary: Value(summary),
      updatedAt: Value(DateTime.now()),
    ));
  }

  Future<void> saveQuiz(String messageId, List<Map<String, dynamic>> quiz) {
    return (_db.update(_db.messages)..where((t) => t.id.equals(messageId)))
        .write(MessagesCompanion(
      quiz: Value(jsonEncode(quiz)),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Records a completed quiz attempt locally (Drift — see
  /// `QuizAttempts` in app_database.dart; PROJECT_MIGRATION_AUDIT.md
  /// Phase 4 replaced the Firestore `quiz_progress` collection this used
  /// to write to, since that write had no way left to prove device
  /// identity to Firestore rules post-Phase-2 Auth removal).
  Future<void> recordQuizAttempt({
    required String messageId,
    required int score,
    required int totalQuestions,
  }) {
    return _db.into(_db.quizAttempts).insert(QuizAttemptsCompanion.insert(
          messageId: messageId,
          score: score,
          totalQuestions: totalQuestions,
          completedAt: DateTime.now(),
        ));
  }

  /// Opt-in content sync: fetches a JSON array in the same shape as
  /// `assets/data/messages.json` from [url] and upserts every entry into
  /// the local Messages table (existing summary/quiz cache is kept
  /// unless the remote entry explicitly provides its own). This is the
  /// only network call anywhere in Impact Academy — never triggered
  /// automatically, only when the user taps a "check for new messages"
  /// action, matching how Radio and AI chat only go online on request.
  ///
  /// [url] is not hardcoded anywhere in the app: whoever hosts an update
  /// feed (a static JSON file on any plain file host — no backend
  /// required) supplies it, e.g. via Settings.
  Future<int> syncFromUrl(String url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception('Sync failed: HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body) as List<dynamic>;
    final incoming = decoded
        .map((e) => ArchivedMessage.fromJson(e as Map<String, dynamic>))
        .toList();

    var updated = 0;
    for (final m in incoming) {
      final existing = await (_db.select(_db.messages)
            ..where((t) => t.id.equals(m.id)))
          .getSingleOrNull();
      // Keep the locally-cached summary/quiz unless the remote entry
      // explicitly supplies its own — a content update shouldn't throw
      // away a Groq summary/quiz that already cost an API call.
      final mergedSummary = m.summary ?? existing?.summary;
      final mergedQuiz = m.quiz != null ? jsonEncode(m.quiz) : existing?.quiz;
      await _db.into(_db.messages).insertOnConflictUpdate(
            MessagesCompanion.insert(
              id: m.id,
              title: m.title,
              category: m.category,
              transcript: m.transcript,
              summary: Value(mergedSummary),
              quiz: Value(mergedQuiz),
              updatedAt: DateTime.now(),
            ),
          );
      updated++;
    }
    return updated;
  }
}
