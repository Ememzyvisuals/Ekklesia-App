import 'dart:convert';
import 'package:http/http.dart' as http;

import 'ai_config.dart';
import 'user_groq_key_service.dart';

class GroqMessage {
  const GroqMessage({required this.role, required this.content});
  final String role; // 'system' | 'user' | 'assistant'
  final String content;

  Map<String, String> toJson() => {'role': role, 'content': content};
}

/// Thrown when [GroqService.chat] is called with no personal Groq key set.
/// Callers should catch this and route to Settings' key entry rather
/// than let a plain network failure surface.
class GroqKeyMissingException implements Exception {
  @override
  String toString() =>
      'GroqKeyMissingException: no Groq API key is set — add one in '
      'Settings to use AI features.';
}

/// Handles all text generation: chat replies, message summaries, and
/// quiz generation for Impact Academy. One model call type, several
/// prompt shapes.
///
/// PROJECT_MIGRATION_AUDIT.md — by explicit instruction: no cloud
/// infrastructure of any kind runs for this app, including a shared-key
/// proxy. Every user supplies their own Groq API key (see
/// [UserGroqKeyService]), stored in secure storage, and this calls
/// Groq's API directly with it. No fallback, no shared quota, no
/// Cloudflare Worker in between — `cloudflare/groq-proxy/` and
/// `device_identity_service.dart` (which existed only to authenticate
/// against that Worker) were both deleted in the same pass as this file.
///
/// [chat] throws [GroqKeyMissingException] if no personal key is set —
/// callers (ai_assistant_screen.dart, message_overview_service.dart,
/// quiz_screen.dart) should catch this and route to Settings' key entry
/// rather than let a network call fail with a confusing 401.
class GroqService {
  GroqService._internal();
  static final GroqService instance = GroqService._internal();

  static const _directChatUrl =
      'https://api.groq.com/openai/v1/chat/completions';

  Future<String> chat(List<GroqMessage> messages) async {
    final personalKey = await UserGroqKeyService.instance.getKey();
    if (personalKey == null) {
      throw GroqKeyMissingException();
    }
    return _chatWithPersonalKey(messages, personalKey);
  }

  Future<String> _chatWithPersonalKey(
    List<GroqMessage> messages,
    String apiKey,
  ) async {
    final response = await http.post(
      Uri.parse(_directChatUrl),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': AIConfig.instance.currentModel,
        'messages': messages.map((m) => m.toJson()).toList(),
      }),
    );

    if (response.statusCode == 401) {
      throw Exception(
        "Your Groq API key was rejected (401) — check it's correct in Settings.",
      );
    }
    if (response.statusCode != 200) {
      throw Exception(
        'Groq request failed (${response.statusCode}): ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = decoded['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      throw Exception('Groq returned an unexpected shape: ${response.body}');
    }
    final content =
        (choices.first as Map<String, dynamic>)['message']?['content'];
    if (content is! String) {
      throw Exception(
        'Groq returned an unexpected message shape: ${response.body}',
      );
    }
    return content;
  }

  /// Generates a short bullet-point summary of a sermon/message transcript.
  Future<String> summarizeMessage(String transcript) {
    return chat([
      const GroqMessage(
        role: 'system',
        content: 'You summarize Christian sermon transcripts into 3-5 short, '
            'clear bullet points highlighting the key teaching points. '
            'Keep language simple and direct.',
      ),
      GroqMessage(role: 'user', content: transcript),
    ]);
  }

  /// Generates a JSON-only multiple-choice quiz from a transcript.
  /// Returns the raw JSON string — parse with [parseQuizJson].
  Future<String> generateQuiz(String transcript, {int questionCount = 5}) {
    return chat([
      GroqMessage(
        role: 'system',
        content: 'You generate multiple-choice quiz questions from a sermon '
            'transcript. Respond with ONLY valid JSON, no markdown fences, '
            'no preamble. Shape: '
            '{"questions": [{"question": "...", "options": ["...","...","...","..."], '
            '"correctIndex": 0}]}. Generate exactly $questionCount questions.',
      ),
      GroqMessage(role: 'user', content: transcript),
    ]);
  }

  List<Map<String, dynamic>> parseQuizJson(String rawJson) {
    final cleaned =
        rawJson.replaceAll('```json', '').replaceAll('```', '').trim();
    final decoded = jsonDecode(cleaned) as Map<String, dynamic>;
    return (decoded['questions'] as List<dynamic>).cast<Map<String, dynamic>>();
  }
}
