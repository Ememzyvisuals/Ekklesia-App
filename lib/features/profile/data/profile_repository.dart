import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

/// Drift-backed replacement for the Firestore `users/{uid}` document
/// (PROJECT_MIGRATION_AUDIT.md Phase 2 — no account system, so no `uid`
/// or `email` anymore). This IS the local profile the spec's "User
/// Profile — No Account System" section describes: displayName,
/// ageGroup, gender, preferredLanguage, avatarId, createdAt/updatedAt.
///
/// Single-row table in practice (one on-device user) — [watch]/[get]
/// return the first row rather than taking an id param, since there's
/// nothing to key by anymore.
class LocalProfile {
  const LocalProfile({
    required this.id,
    required this.displayName,
    required this.ageGroup,
    required this.gender,
    required this.preferredLanguage,
    required this.avatarId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String displayName;
  final String ageGroup;
  final String gender;
  final String preferredLanguage;
  final String avatarId;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class ProfileRepository {
  ProfileRepository(this.db);
  final AppDatabase db;

  Stream<LocalProfile?> watch() {
    return db.select(db.localProfiles).watch().map(
        (rows) => rows.isEmpty ? null : _toModel(rows.first));
  }

  Future<LocalProfile?> get() async {
    final row = await db.select(db.localProfiles).getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  Future<bool> hasProfile() async => (await get()) != null;

  /// Called once by onboarding. Generates the profile id here rather
  /// than accepting one — callers never need to invent an id.
  Future<LocalProfile> create({
    required String displayName,
    required String ageGroup,
    required String gender,
    required String preferredLanguage,
    required String avatarId,
  }) async {
    final now = DateTime.now();
    final id = const Uuid().v4();
    await db.into(db.localProfiles).insert(
          LocalProfilesCompanion.insert(
            id: id,
            displayName: displayName,
            ageGroup: ageGroup,
            gender: gender,
            preferredLanguage: preferredLanguage,
            avatarId: avatarId,
            createdAt: now,
            updatedAt: now,
          ),
        );
    return LocalProfile(
      id: id,
      displayName: displayName,
      ageGroup: ageGroup,
      gender: gender,
      preferredLanguage: preferredLanguage,
      avatarId: avatarId,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<void> update({
    String? displayName,
    String? avatarId,
    String? preferredLanguage,
  }) async {
    final existing = await get();
    if (existing == null) {
      throw StateError('update() called before onboarding created a profile.');
    }
    await (db.update(db.localProfiles)
          ..where((t) => t.id.equals(existing.id)))
        .write(LocalProfilesCompanion(
      displayName: displayName != null
          ? Value(displayName)
          : const Value.absent(),
      avatarId: avatarId != null ? Value(avatarId) : const Value.absent(),
      preferredLanguage: preferredLanguage != null
          ? Value(preferredLanguage)
          : const Value.absent(),
      updatedAt: Value(DateTime.now()),
    ));
  }

  LocalProfile _toModel(dynamic row) => LocalProfile(
        id: row.id,
        displayName: row.displayName,
        ageGroup: row.ageGroup,
        gender: row.gender,
        preferredLanguage: row.preferredLanguage,
        avatarId: row.avatarId,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      );
}
