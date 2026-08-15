import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores the user's personal Groq API key (from console.groq.com/keys)
/// so [GroqService] can call Groq directly with it.
///
/// PROJECT_MIGRATION_AUDIT.md: by explicit instruction, this app runs no
/// cloud infrastructure of its own — every user brings their own Groq
/// key, there is no shared proxy/Worker and no shared quota to fall back
/// to (see GroqService/AIConfig's rewritten doc comments). That makes
/// this key mandatory for AI features rather than optional, which is
/// also why it moved to secure storage here (was SharedPreferences,
/// added to pubspec.yaml back in an earlier phase but never actually
/// wired up until now — a real, previously-flagged gap, closed here
/// rather than left for later now that the key matters more than it
/// used to).
class UserGroqKeyService {
  UserGroqKeyService._internal();
  static final UserGroqKeyService instance = UserGroqKeyService._internal();

  static const _key = 'user_groq_api_key';
  final _storage = const FlutterSecureStorage();

  Future<String?> getKey() async {
    final value = await _storage.read(key: _key);
    return (value == null || value.trim().isEmpty) ? null : value.trim();
  }

  Future<bool> hasKey() async => (await getKey()) != null;

  Future<void> setKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await clearKey();
      return;
    }
    await _storage.write(key: _key, value: trimmed);
  }

  Future<void> clearKey() async {
    await _storage.delete(key: _key);
  }

  /// Masks a key for display — e.g. "gsk_...a1B2" — never show the full
  /// key back once saved.
  static String mask(String key) {
    if (key.length <= 8) return '••••••••';
    return '${key.substring(0, 4)}...${key.substring(key.length - 4)}';
  }
}
