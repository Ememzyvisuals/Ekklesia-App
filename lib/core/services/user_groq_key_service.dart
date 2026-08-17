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
    // Uncovered by the 5-minute-frozen-splash bug: this is called during
    // AIConfig.verify() at app startup, before any other timeout
    // protection applies. flutter_secure_storage's Android Keystore
    // read has known reports of hanging (not throwing — hanging)
    // indefinitely on certain devices/OEM skins, most often on the very
    // first Keystore access on a fresh install, which is exactly what
    // every user's first app launch is. Without this timeout, that
    // single native call could freeze main() before runApp() forever,
    // with no error, no crash, nothing — just a permanently frozen
    // splash screen, which is exactly what got reported. A missing
    // Groq key is a normal, expected state (most users haven't set one
    // yet); it must never be allowed to block the app from opening.
    try {
      final value =
          await _storage.read(key: _key).timeout(const Duration(seconds: 3));
      return (value == null || value.trim().isEmpty) ? null : value.trim();
    } catch (_) {
      return null;
    }
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
