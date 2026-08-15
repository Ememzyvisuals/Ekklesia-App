import 'dart:async';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/services/groq_service.dart';
import '../../../core/services/tts_service.dart';
import '../../../core/services/audio_service.dart';
import '../../../core/services/conversation_worker.dart';
import '../../../core/services/download_worker.dart';
import '../../../core/services/user_groq_key_service.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../core/config/app_theme.dart';
import '../data/conversation_repository.dart';
import '../domain/conversation.dart';

/// AI Bible assistant — real Groq-backed chat, with a "Listen" action per
/// assistant reply that routes to the correct TTS engine/persona via
/// TtsService.
///
/// Chat turns are persisted via ConversationWorker/ConversationRepository
/// (see core/services/conversation_worker.dart) to `ai_conversations` —
/// closing the "in-memory only, lost on restart" gap the original scaffold
/// had. Each calendar day gets a fresh session id, reused for every open
/// that same day; history for today's session loads on screen init so a
/// restart mid-day doesn't lose the conversation.
class AiAssistantScreen extends StatefulWidget {
  const AiAssistantScreen({super.key});

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _ChatEntry {
  _ChatEntry({required this.id, required this.role, required this.text});
  final String id;
  final String role; // 'user' | 'assistant'
  final String text;
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  final _inputController = TextEditingController();
  final List<_ChatEntry> _history = [];
  bool _sending = false;
  bool _loadingHistory = true;
  String? _error;
  // PROJECT_MIGRATION_AUDIT.md: renamed from _isUsageLimitError — there's
  // no shared daily quota anymore (every user brings their own Groq
  // key), so the only reason chat fails this way now is a missing key.
  bool _needsGroqKey = false;
  late final String _sessionId;
  final _random = Random();

  static const _systemPrompt = GroqMessage(
    role: 'system',
    content: 'You are a warm, biblically grounded Christian assistant for the '
        'Ekklesia app. Answer questions about scripture, offer to write '
        'short prayers or devotionals when asked, and keep answers clear '
        'and encouraging. Keep responses reasonably short for a mobile '
        'chat interface.',
  );

  @override
  void initState() {
    super.initState();
    _sessionId = _todaysSessionId();
    _loadHistory();
  }

  /// One session per calendar day (`chat-yyyy-MM-dd`) — matches the doc
  /// comment on ConversationMessage.sessionId ("reuses the most recent
  /// open session for that day").
  String _todaysSessionId() {
    final now = DateTime.now();
    return 'chat-${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  String _newMessageId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';

  Future<void> _loadHistory() async {
    try {
      final messages = await ConversationRepository.instance
          .sessionMessages(_sessionId)
          .first
          .timeout(const Duration(seconds: 5));
      if (!mounted) {
        return;
      }
      setState(() {
        _history.addAll(messages.map(
          (m) => _ChatEntry(id: m.id, role: m.role, text: m.text),
        ));
        _loadingHistory = false;
      });
    } catch (_) {
      // Nothing cached yet for today's session — not fatal, just start
      // with an empty history.
      if (mounted) {
        setState(() => _loadingHistory = false);
      }
    }
  }

  Future<void> _persist(_ChatEntry entry) async {
    // No more uid/auth gate here (PROJECT_MIGRATION_AUDIT.md Phase 2 —
    // no accounts at all) and no more offline-queue concern
    // (Phase 4 — ConversationRepository is Drift-backed, a local write
    // doesn't fail because the device is offline).
    await ConversationWorker.instance.record(ConversationMessage(
      id: entry.id,
      sessionId: _sessionId,
      role: entry.role,
      text: entry.text,
      createdAt: DateTime.now(),
    ));
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) {
      return;
    }

    final userEntry = _ChatEntry(id: _newMessageId(), role: 'user', text: text);
    setState(() {
      _history.add(userEntry);
      _inputController.clear();
      _sending = true;
      _error = null;
      _needsGroqKey = false;
    });
    unawaited(_persist(userEntry));

    try {
      final messages = [
        _systemPrompt,
        ..._history.map((e) => GroqMessage(role: e.role, content: e.text)),
      ];
      final reply = await GroqService.instance.chat(messages);
      final assistantEntry =
          _ChatEntry(id: _newMessageId(), role: 'assistant', text: reply);
      setState(() => _history.add(assistantEntry));
      unawaited(_persist(assistantEntry));
    } on GroqKeyMissingException {
      setState(() {
        _needsGroqKey = true;
        _error = 'Add your Groq API key in Settings to use the AI Assistant.';
      });
    } catch (e) {
      setState(() {
        _needsGroqKey = false;
        _error = e.toString();
      });
    } finally {
      setState(() => _sending = false);
    }
  }

  int? _listeningIndex;
  String? _queueProgressLabel;
  StreamSubscription<(int, int)?>? _queueProgressSub;
  final Set<int> _savedIndices = {};
  int? _savingIndex;

  /// Downloads a reply's TTS audio via DownloadWorker so it plays back
  /// offline later from the Downloads screen. Multi-chunk replies (longer
  /// than one on-device synthesis call comfortably handles at once — see
  /// AppConfig.onDeviceTtsMaxChars) are saved as separate numbered parts
  /// rather than merged into one file; merging audio client-side is out
  /// of scope for this pass.
  Future<void> _saveOffline(String text, int index) async {
    setState(() => _savingIndex = index);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final chunks = TtsService.instance.synthesizeChunks(
        text: text,
        language: EkklesiaLanguage.english,
      );
      final label = 'AI reply ${DateTime.now().millisecondsSinceEpoch}';
      var part = 1;
      var total = 0;
      await for (final result in chunks) {
        await DownloadWorker.instance.enqueue(
          title: '$label (part $part)',
          sourceUrl: result.audioUrl,
          localPath: '${dir.path}/ekklesia_downloads/${label}_p$part.mp3',
        );
        part++;
        total++;
      }
      if (!mounted) {
        return;
      }
      setState(() => _savedIndices.add(index));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(total > 1
                ? 'Saving $total parts to Downloads…'
                : 'Saving to Downloads…')),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save offline: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _savingIndex = null);
      }
    }
  }

  Future<void> _listenTo(String text, int index) async {
    setState(() {
      _listeningIndex = index;
      _queueProgressLabel = null;
      _error = null;
    });
    _queueProgressSub?.cancel();
    _queueProgressSub =
        AudioService.instance.queueProgressStream.listen((progress) {
      if (!mounted) {
        return;
      }
      setState(() {
        _queueProgressLabel =
            progress == null ? null : 'Part ${progress.$1 + 1}/${progress.$2}';
      });
    });
    try {
      // AI replies can run long, so this splits into chunks
      // (AppConfig.onDeviceTtsMaxChars) and plays them back-to-back
      // rather than sending the whole reply to the on-device engine in
      // one call — bounds how long a single synthesis call blocks and
      // gives look-ahead prefetch a meaningful unit to work with.
      final chunks = TtsService.instance.synthesizeChunks(
        text: text,
        language: EkklesiaLanguage.english,
      );
      await AudioService.instance.playQueue(
        chunks.map((r) => (r.audioUrl, r.source)),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() {
        _listeningIndex = null;
        _queueProgressLabel = null;
      });
    }
  }

  @override
  void dispose() {
    _queueProgressSub?.cancel();
    _inputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).aiAssistantTitle),
        actions: [
          FutureBuilder<bool>(
            future: UserGroqKeyService.instance.hasKey(),
            builder: (context, hasKeySnapshot) {
              if (hasKeySnapshot.data == true) {
                return const SizedBox.shrink();
              }
              // PROJECT_MIGRATION_AUDIT.md: replaced the old shared-quota
              // "N calls remaining today" indicator — there's no shared
              // quota anymore, every user brings their own key, so the
              // only meaningful state to show here is "you need one."
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Center(
                  child: TextButton(
                    onPressed: () => context.push('/settings'),
                    child: const Text('Add Groq key',
                        style: TextStyle(fontSize: 12)),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loadingHistory
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _history.length,
                    itemBuilder: (context, index) {
                      final entry = _history[index];
                      final isUser = entry.role == 'user';
                      return Align(
                        alignment: isUser
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          padding: const EdgeInsets.all(12),
                          constraints: const BoxConstraints(maxWidth: 280),
                          decoration: BoxDecoration(
                            color:
                                isUser ? AppColors.primary : AppColors.surface,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.text,
                                style: TextStyle(
                                    color: isUser
                                        ? Colors.white
                                        : AppColors.textPrimary),
                              ),
                              if (!isUser) ...[
                                const SizedBox(height: 6),
                                Builder(builder: (context) {
                                  final isPlaying = _listeningIndex == index;
                                  return InkWell(
                                    onTap: isPlaying
                                        ? null
                                        : () => _listenTo(entry.text, index),
                                    child: Row(
                                      children: [
                                        isPlaying
                                            ? const SizedBox(
                                                height: 12,
                                                width: 12,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: AppColors.accent,
                                                ),
                                              )
                                            : const Icon(
                                                CupertinoIcons.speaker_2_fill,
                                                size: 16,
                                                color: AppColors.accent),
                                        const SizedBox(width: 4),
                                        Text(
                                          isPlaying
                                              ? (_queueProgressLabel ??
                                                  'Loading...')
                                              : 'Listen',
                                          style: const TextStyle(
                                              color: AppColors.accent,
                                              fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                                const SizedBox(height: 4),
                                Builder(builder: (context) {
                                  final isSaving = _savingIndex == index;
                                  final isSaved = _savedIndices.contains(index);
                                  return InkWell(
                                    onTap: (isSaving || isSaved)
                                        ? null
                                        : () => _saveOffline(entry.text, index),
                                    child: Row(
                                      children: [
                                        isSaving
                                            ? const SizedBox(
                                                height: 12,
                                                width: 12,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: AppColors.accent,
                                                ),
                                              )
                                            : Icon(
                                                isSaved
                                                    ? CupertinoIcons
                                                        .checkmark_alt_circle_fill
                                                    : CupertinoIcons
                                                        .cloud_download,
                                                size: 16,
                                                color: AppColors.accent,
                                              ),
                                        const SizedBox(width: 4),
                                        Text(
                                          isSaved
                                              ? 'Saved offline'
                                              : (isSaving
                                                  ? 'Saving...'
                                                  : 'Save offline'),
                                          style: const TextStyle(
                                              color: AppColors.accent,
                                              fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.red))),
                  if (_needsGroqKey)
                    TextButton(
                      onPressed: () => context.push('/settings'),
                      child: Text(AppLocalizations.of(context).navSettings),
                    ),
                ],
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      decoration: const InputDecoration(
                        hintText: 'Ask something, or request a prayer...',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(CupertinoIcons.paperplane_fill),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
