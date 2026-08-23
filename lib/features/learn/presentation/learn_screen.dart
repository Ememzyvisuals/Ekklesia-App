import 'package:flutter/material.dart';

import '../data/message_repository.dart';
import '../../../core/services/groq_service.dart';
import '../../../core/config/app_theme.dart';
import '../../../core/widgets/markdown_text.dart';
import 'quiz_screen.dart';

/// Impact Academy — local, Drift-backed archive seeded from the bundled
/// `assets/data/messages.json` catalog (see MessageRepository). Tapping
/// a message generates (or loads a cached) AI summary via Groq, with a
/// button to take the AI-generated quiz.
///
/// Verse Rush / Sermon Detective are lighter, no-backend mini-games —
/// separate screens, not built here yet (next step after this list
/// works end-to-end).
class LearnScreen extends StatefulWidget {
  const LearnScreen({super.key});

  @override
  State<LearnScreen> createState() => _LearnScreenState();
}

class _LearnScreenState extends State<LearnScreen> {
  static const _category = 'Impact Academy';
  List<ArchivedMessage> _messages = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final messages =
          await MessageRepository.instance.getByCategory(_category);
      setState(() => _messages = messages);
    } catch (_) {
      // Was `_error = e.toString()` — dumped raw exception text into
      // the UI, same class of bug already fixed on the AI/Live/Bible
      // screens but missed here. This is a local read, not a network
      // call, so a generic message fits every real failure mode.
      setState(() =>
          _error = 'Could not load Impact Academy content. Try again.');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Impact Academy')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Text(_error!,
                        style: const TextStyle(color: Colors.red)))
                : _messages.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No messages yet.\n\nAdd entries with '
                            'category="Impact Academy" (id, title, transcript) '
                            'to assets/data/messages.json to see them here.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) =>
                            _MessageTile(message: _messages[index]),
                      ),
      ),
    );
  }
}

class _MessageTile extends StatefulWidget {
  const _MessageTile({required this.message});
  final ArchivedMessage message;

  @override
  State<_MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<_MessageTile> {
  bool _expanded = false;
  bool _generating = false;
  String? _summary;
  List<Map<String, dynamic>>? _quiz;

  @override
  void initState() {
    super.initState();
    _summary = widget.message.summary;
    _quiz = widget.message.quiz;
  }

  Future<void> _generateSummaryAndQuiz() async {
    setState(() => _generating = true);
    try {
      if (_summary == null) {
        final summary = await GroqService.instance
            .summarizeMessage(widget.message.transcript);
        await MessageRepository.instance
            .saveSummary(widget.message.id, summary);
        setState(() => _summary = summary);
      }
      if (_quiz == null) {
        final quizJson =
            await GroqService.instance.generateQuiz(widget.message.transcript);
        final parsed = GroqService.instance.parseQuizJson(quizJson);
        await MessageRepository.instance.saveQuiz(widget.message.id, parsed);
        setState(() => _quiz = parsed);
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      // Was `'Error: $e'` — confirmed on a real device: this dumped the
      // full raw ClientException/SocketException text (including the
      // literal API URL) straight into a SnackBar. Same friendly-error
      // categorization already used on the AI Assistant screen.
      final message = e.toString().toLowerCase();
      final friendly = message.contains('socketexception') ||
              message.contains('failed host lookup') ||
              message.contains('network is unreachable')
          ? "You're offline. Connect to the internet and try again."
          : message.contains('model_decommissioned') ||
                  message.contains('400') ||
                  message.contains('404')
              ? 'The AI model is temporarily unavailable. Try again shortly.'
              : message.contains('401') || message.contains('403')
                  ? 'Your Groq API key was rejected. Check it in Settings.'
                  : 'Could not generate the summary. Try again.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendly)));
    } finally {
      if (mounted) {
        setState(() => _generating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            title: Text(widget.message.title,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            trailing: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_summary != null) ...[
                    Text('Summary',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    // Was Text(_summary!) — showed Groq's raw Markdown
                    // (the **bold**/`- ` list markers visible in the
                    // Impact Academy screenshots) straight to the user.
                    MarkdownText(
                      _summary!,
                      baseStyle: TextStyle(color: AppTheme.textPrimary(context)),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_generating)
                    const Center(child: CircularProgressIndicator())
                  else if (_summary == null || _quiz == null)
                    ElevatedButton(
                      onPressed: _generateSummaryAndQuiz,
                      child: const Text('Generate Summary + Quiz'),
                    )
                  else
                    ElevatedButton.icon(
                      icon: const Icon(Icons.quiz),
                      label: const Text('Take Quiz'),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => QuizScreen(
                              messageId: widget.message.id,
                              questions: _quiz!,
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
