import 'dart:async';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/groq_service.dart';
import '../../../core/services/conversation_worker.dart';
import '../../../core/services/user_groq_key_service.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../core/config/app_theme.dart';
import '../../../core/config/app_config.dart';
import '../data/conversation_repository.dart';
import '../domain/conversation.dart';
import '../../../core/widgets/ekklesia_companion.dart';
import '../../../core/widgets/markdown_text.dart';

/// AI Bible assistant — real Groq-backed chat. Previously had a "Listen"
/// action per assistant reply (TtsService-backed) and a "Save offline"
/// download action — both REMOVED along with TTS entirely (see
/// pubspec.yaml's removal notes); AI replies are dynamically generated
/// text with no pre-recorded audio to fall back to.
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
  // Same pattern as bible_screen.dart's _errorDetail — the friendly
  // message shown by default, the real exception text one tap away
  // behind "Details" instead of nowhere at all.
  String? _errorDetail;
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
      _errorDetail = null;
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
        _errorDetail = e.toString();
      });
    } finally {
      setState(() => _sending = false);
    }
  }

  // Listen / Save offline features REMOVED entirely along with TTS
  // (see pubspec.yaml's removal notes) — _listenTo/_saveOffline and
  // their state (_listeningIndex, _savingIndex, _savedIndices,
  // _queueProgressLabel/_queueProgressSub) all used TtsService/
  // AudioService, both deleted. AI replies are dynamically generated
  // text with nothing pre-recorded to fall back to (unlike the Bible
  // screen, which can use downloaded audio instead).

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
                                              color:
                                                  AppTheme.textPrimary(
                                                      context)),
                                        ),
                                  // Listen / Save offline buttons REMOVED
                                  // — both were TTS-based (see
                                  // pubspec.yaml's removal notes), and
                                  // AI replies are dynamically generated
                                  // text with nothing pre-recorded to
                                  // fall back to, unlike the Bible
                                  // screen.
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!,
                            style: const TextStyle(color: Colors.red)),
                        if (_errorDetail != null)
                          InkWell(
                            onTap: () => showDialog<void>(
                              context: context,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text('Error details'),
                                content: SingleChildScrollView(
                                  child: SelectableText(
                                      '${_errorDetail ?? ''}\n\n(build: ${AppConfig.buildTag})'),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(dialogContext).pop(),
                                    child: const Text('Close'),
                                  ),
                                ],
                              ),
                            ),
                            child: const Padding(
                              padding: EdgeInsets.only(top: 2),
                              child: Text('Details',
                                  style: TextStyle(
                                      color: Colors.red,
                                      decoration: TextDecoration.underline,
                                      fontSize: 12)),
                            ),
                          ),
                      ],
                    ),
                  ),
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
