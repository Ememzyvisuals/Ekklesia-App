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
import '../../../core/widgets/ekklesia_companion.dart';
import '../../../core/widgets/markdown_text.dart';

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
  const AiAssistantScreen({super.key, this.initialMessage});

  /// Set when arriving from Home's "Today's Prayer" card — that text
  /// gets sent to the AI automatically on arrival, rather than landing
  /// on a blank chat and leaving the person to copy/retype it
  /// themselves.
  final String? initialMessage;

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
  // Was `late final` — one session per calendar day, fixed for the
  // screen's lifetime. Needs to be mutable now: switching to a past
  // conversation from the history drawer, or starting a fresh "New
  // Chat", both reassign this to a different session.
  String _sessionId = '';
  bool _initialMessageHandled = false;
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
    setState(() {
      _history.clear();
      _loadingHistory = true;
      _error = null;
    });
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
      // Nothing cached yet for this session — not fatal, just start
      // with an empty history.
      if (mounted) {
        setState(() => _loadingHistory = false);
      }
    }
    _maybeSendInitialMessage();
  }

  /// Starts a brand-new, empty conversation with a fresh session id —
  /// the "New Chat" action in the history drawer.
  void _startNewChat() {
    setState(() => _sessionId = _newSessionId());
    _loadHistory();
  }

  /// Switches to viewing a past conversation from the history drawer.
  void _switchToSession(String sessionId) {
    if (sessionId == _sessionId) {
      Navigator.of(context).pop(); // just close the drawer
      return;
    }
    setState(() => _sessionId = sessionId);
    _loadHistory();
    Navigator.of(context).pop();
  }

  String _newSessionId() {
    final now = DateTime.now();
    return 'chat-${now.millisecondsSinceEpoch}-${_random.nextInt(99999)}';
  }

  /// Auto-sends widget.initialMessage (the prayer text, when arriving
  /// from Home) exactly once, ever — guarded separately from
  /// _history.isEmpty so switching sessions later never re-triggers it,
  /// and only into a genuinely empty chat — if today's session already
  /// has messages, silently do nothing rather than injecting the prayer
  /// into an existing conversation the
  /// person is already having.
  void _maybeSendInitialMessage() {
    if (_initialMessageHandled) return;
    _initialMessageHandled = true;
    final message = widget.initialMessage;
    if (message == null || message.trim().isEmpty || _history.isNotEmpty) {
      return;
    }
    // The prayer text arrives straight from Groq (Markdown formatting
    // and all) — stripped here so it doesn't show raw `**`/`- ` syntax
    // in the user's own chat bubble, which (unlike the assistant's
    // replies) isn't run through MarkdownText.
    _sendSuggested(stripMarkdown(message));
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

  /// Fills the input with a suggested prompt (from the empty-state
  /// companion's suggestion chips) and sends it immediately — a tap
  /// should feel like picking a ready-made message, not just
  /// pre-filling the box for the person to press send themselves.
  void _sendSuggested(String text) {
    _inputController.text = text;
    _send();
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
        // Was `_error = e.toString()` — dumped raw exception text
        // straight into the chat UI (e.g. "ClientException with
        // SocketException: Failed host lookup: 'api.groq.com' (OS
        // Error: No address associated with hostname, errno = 7)"),
        // which is exactly what a person sees on a real device with no
        // internet. A person doesn't need the OS errno; they need to
        // know the AI needs a connection and their message wasn't
        // lost.
        final message = e.toString().toLowerCase();
        if (message.contains('socketexception') ||
            message.contains('failed host lookup') ||
            message.contains('network is unreachable') ||
            message.contains('connection refused') ||
            message.contains('connection timed out')) {
          _error = "You're offline. The AI Assistant needs an internet "
              "connection. Try again once you're back online.";
        } else if (message.contains('401') || message.contains('403')) {
          _error = 'Your Groq API key was rejected. Check it in Settings.';
        } else if (message.contains('429')) {
          _error = "You've hit Groq's rate limit. Wait a moment and try "
              'again.';
        } else if (message.contains('timeoutexception')) {
          _error = 'The request took too long. Try again.';
        } else {
          _error = 'Something went wrong sending that message. Try again.';
        }
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
      // Same raw-exception-in-the-UI bug already fixed on the main send
      // path in this file, but missed here on the Listen/TTS path.
      final message = e.toString().toLowerCase();
      setState(() => _error = message.contains('socketexception') ||
              message.contains('failed host lookup')
          ? "You're offline. Voice playback needs an internet connection."
          : 'Could not play that message. Try again.');
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
      // Adding `drawer:` here is what actually gives the menu icon in
      // the AppBar's leading (left) position — that's Scaffold's own
      // built-in behavior, not something built by hand. Matches the
      // explicit request for a menu on the left side that opens
      // conversation history.
      drawer: _ConversationHistoryDrawer(
        currentSessionId: _sessionId,
        onSelectSession: _switchToSession,
        onNewChat: () {
          Navigator.of(context).pop();
          _startNewChat();
        },
      ),
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
                : _history.isEmpty
                    ? _AiEmptyState(onSuggestionTap: _sendSuggested)
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
                                color: isUser
                                    ? AppColors.primary
                                    : AppTheme.surface(context),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Groq replies come back as Markdown
                                  // (headers, **bold**, lists, tables) —
                                  // was rendered as a plain Text() before,
                                  // showing raw `**`/`#`/`|` characters
                                  // straight in the chat bubble. The
                                  // user's own messages are never
                                  // Markdown, so only the AI side goes
                                  // through the renderer.
                                  isUser
                                      ? Text(
                                          entry.text,
                                          style: const TextStyle(
                                              color: Colors.white),
                                        )
                                      : MarkdownText(
                                          entry.text,
                                          baseStyle: TextStyle(
                                              color: AppTheme.textPrimary(
                                                  context)),
                                        ),
                                  if (!isUser) ...[
                                    const SizedBox(height: 6),
                                    Builder(builder: (context) {
                                      final isPlaying =
                                          _listeningIndex == index;
                                      return InkWell(
                                        onTap: isPlaying
                                            ? null
                                            : () =>
                                                _listenTo(entry.text, index),
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
                                                    CupertinoIcons
                                                        .speaker_2_fill,
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
                                      final isSaved =
                                          _savedIndices.contains(index);
                                      return InkWell(
                                        onTap: (isSaving || isSaved)
                                            ? null
                                            : () =>
                                                _saveOffline(entry.text, index),
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

/// Shown only until the first message is sent — matches the explicit
/// request: the AI companion sits here, with suggestion chips mirroring
/// the supplied character art's own speech-bubble prompts ("Explain
/// this verse" / "Help me pray" / "Give me a devotional"), and
/// disappears the moment there's real conversation to show instead.
class _AiEmptyState extends StatelessWidget {
  const _AiEmptyState({required this.onSuggestionTap});

  final ValueChanged<String> onSuggestionTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const EkklesiaCompanion(
              type: EkklesiaCompanionType.ai,
              width: 140,
              animate: true,
            ),
            const SizedBox(height: 12),
            Text(
              'How can I help you today?',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary(context),
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _SuggestionChip(
                  icon: Icons.menu_book_outlined,
                  label: 'Explain this verse',
                  onTap: () => onSuggestionTap(
                      'Explain the meaning of John 3:16 in simple terms.'),
                ),
                _SuggestionChip(
                  icon: Icons.volunteer_activism_outlined,
                  label: 'Help me pray',
                  onTap: () => onSuggestionTap(
                      'Help me write a short prayer for peace and guidance today.'),
                ),
                _SuggestionChip(
                  icon: Icons.chat_bubble_outline,
                  label: 'Give me a devotional',
                  onTap: () => onSuggestionTap(
                      'Give me a short devotional to start my day.'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip(
      {required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface(context),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: AppColors.accent),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One entry in the conversation history drawer — one row per session
/// (not per message), showing that session's first user message as a
/// preview and when it was last active.
class _SessionSummary {
  const _SessionSummary(
      {required this.sessionId,
      required this.preview,
      required this.lastActive});
  final String sessionId;
  final String preview;
  final DateTime lastActive;
}

class _ConversationHistoryDrawer extends StatelessWidget {
  const _ConversationHistoryDrawer({
    required this.currentSessionId,
    required this.onSelectSession,
    required this.onNewChat,
  });

  final String currentSessionId;
  final ValueChanged<String> onSelectSession;
  final VoidCallback onNewChat;

  /// Groups the flat message list into one summary per session,
  /// ordered by that session's most recent message — this is a local
  /// Drift read (allMessages already exists for exactly this kind of
  /// use), not a new query concept.
  Future<List<_SessionSummary>> _loadSessions() async {
    final messages = await ConversationRepository.instance.allMessages();
    final bySession = <String, List<ConversationMessage>>{};
    for (final m in messages) {
      bySession.putIfAbsent(m.sessionId, () => []).add(m);
    }
    final summaries = bySession.entries.map((entry) {
      final msgs = entry.value; // already newest-first from allMessages()
      final firstUserMsg = msgs.lastWhere(
        (m) => m.role == 'user',
        orElse: () => msgs.last,
      );
      return _SessionSummary(
        sessionId: entry.key,
        preview: firstUserMsg.text,
        lastActive: msgs.first.createdAt,
      );
    }).toList();
    summaries.sort((a, b) => b.lastActive.compareTo(a.lastActive));
    return summaries;
  }

  String _relativeDay(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(that).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return '$diff days ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Conversations',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary(context),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ElevatedButton.icon(
                onPressed: onNewChat,
                icon: const Icon(Icons.add),
                label: const Text('New Chat'),
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<List<_SessionSummary>>(
                future: _loadSessions(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final sessions = snapshot.data!;
                  if (sessions.isEmpty) {
                    return Center(
                      child: Text(
                        'No past conversations yet',
                        style:
                            TextStyle(color: AppTheme.textSecondary(context)),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: sessions.length,
                    itemBuilder: (context, i) {
                      final s = sessions[i];
                      final isCurrent = s.sessionId == currentSessionId;
                      return ListTile(
                        selected: isCurrent,
                        leading: const Icon(Icons.chat_bubble_outline),
                        title: Text(
                          s.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(_relativeDay(s.lastActive)),
                        onTap: () => onSelectSession(s.sessionId),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
