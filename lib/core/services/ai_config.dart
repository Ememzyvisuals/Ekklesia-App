import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'user_groq_key_service.dart';

/// Central model-selection layer for Groq, per the "never hardcode a model"
/// build rule. GroqService reads [currentModel] instead of a literal string,
/// so swapping models — including an automatic fallback — never touches
/// business logic in GroqService itself.
///
/// Call [AIConfig.instance.verify] once at app bootstrap (before any chat UI
/// is shown), and again whenever the user changes their Groq key in
/// Settings. If it's never called (or no personal key is set yet),
/// [currentModel] safely defaults to [AppConfig.groqPreferredModel] —
/// verify() only ever narrows to a model that's confirmed available, it
/// never widens beyond the supported list.
///
/// PROJECT_MIGRATION_AUDIT.md — calls Groq's own `/openai/v1/models`
/// endpoint directly with the user's personal key, not a proxy. No
/// Cloudflare Worker involved at all (the old `groq-proxy` Worker and
/// its device-token auth existed only to protect a shared key that no
/// longer exists — every user brings their own key now).
class AIConfig {
  AIConfig._internal();
  static final AIConfig instance = AIConfig._internal();

  String _currentModel = AppConfig.groqPreferredModel;
  String get currentModel => _currentModel;

  bool _verified = false;
  bool get isVerified => _verified;

  /// Fetches Groq's live model list (directly from Groq's API, using the
  /// user's own key) and picks the first entry from
  /// [AppConfig.groqSupportedModels] that's actually present. Falls back
  /// to the configured default (last-resort) if no key is set yet or the
  /// call fails — deliberately optimistic rather than blocking app
  /// startup on a network call succeeding.
  Future<void> verify() async {
    try {
      final apiKey = await UserGroqKeyService.instance.getKey();
      if (apiKey == null) {
        _verified = false;
        return;
      }

      final response = await http.get(
        Uri.parse('https://api.groq.com/openai/v1/models'),
        headers: {'Authorization': 'Bearer $apiKey'},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        _verified = false;
        return;
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final liveIds = ((decoded['data'] as List<dynamic>? ?? []))
          .whereType<Map<String, dynamic>>()
          .map((m) => m['id'])
          .whereType<String>()
          .toSet();

      for (final candidate in AppConfig.groqSupportedModels) {
        if (liveIds.contains(candidate)) {
          _currentModel = candidate;
          _verified = true;
          return;
        }
      }

      // None of the supported models are live — keep the default so chat
      // still attempts the call (Groq's own error message is more useful to
      // surface than silently disabling the feature).
      _verified = false;
    } catch (_) {
      // No key set yet, invalid key, network failure, timeout — fail open
      // with the preferred default rather than blocking startup.
      _verified = false;
    }
  }
}
