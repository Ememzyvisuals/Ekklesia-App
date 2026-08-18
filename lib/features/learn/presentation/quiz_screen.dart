import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/message_repository.dart';
import '../../../core/config/app_theme.dart';

/// Takes the AI-generated quiz for a message, scores it, and records the
/// attempt locally (Drift's `quiz_progress` — PROJECT_MIGRATION_AUDIT.md
/// Phase 4).
class QuizScreen extends StatefulWidget {
  const QuizScreen(
      {super.key, required this.messageId, required this.questions});

  final String messageId;
  final List<Map<String, dynamic>> questions;

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  int _currentIndex = 0;
  int _score = 0;
  int? _selectedOption;
  bool _answered = false;
  bool _finished = false;

  void _selectOption(int index) {
    if (_answered) {
      return;
    }
    final correctIndex = widget.questions[_currentIndex]['correctIndex'] as int;
    setState(() {
      _selectedOption = index;
      _answered = true;
      if (index == correctIndex) {
        _score++;
      }
    });
  }

  Future<void> _next() async {
    if (_currentIndex + 1 < widget.questions.length) {
      setState(() {
        _currentIndex++;
        _selectedOption = null;
        _answered = false;
      });
    } else {
      setState(() => _finished = true);
      // No more uid gate needed (PROJECT_MIGRATION_AUDIT.md Phase 4 —
      // recordQuizAttempt is Drift-backed, local, no identity required).
      try {
        await MessageRepository.instance.recordQuizAttempt(
          messageId: widget.messageId,
          score: _score,
          totalQuestions: widget.questions.length,
        );
      } catch (_) {
        // Non-fatal for the user's experience — they still see their score.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_finished) {
      return Scaffold(
        appBar: AppBar(title: const Text('Quiz Complete')),
        body: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
            builder: (context, value, child) => Opacity(
              opacity: value,
              child:
                  Transform.scale(scale: 0.94 + (0.06 * value), child: child),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(CupertinoIcons.rosette,
                    size: 64, color: AppColors.primary),
                const SizedBox(height: 16),
                Text(
                  'You scored $_score / ${widget.questions.length}',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final question = widget.questions[_currentIndex];
    final options = (question['options'] as List<dynamic>).cast<String>();
    final correctIndex = question['correctIndex'] as int;

    return Scaffold(
      appBar: AppBar(
          title: Text(
              'Question ${_currentIndex + 1} / ${widget.questions.length}')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              question['question'] as String,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 20),
            ...List.generate(options.length, (i) {
              Color? color;
              IconData? trailingIcon;
              Color? iconColor;
              if (_answered) {
                if (i == correctIndex) {
                  color = Colors.green.shade100;
                  trailingIcon = CupertinoIcons.check_mark_circled_solid;
                  iconColor = Colors.green.shade700;
                } else if (i == _selectedOption) {
                  color = Colors.red.shade100;
                  trailingIcon = CupertinoIcons.xmark_circle_fill;
                  iconColor = Colors.red.shade700;
                }
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _selectOption(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: color ?? AppTheme.surface(context),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: AppColors.accent.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      children: [
                        Expanded(child: Text(options[i])),
                        if (trailingIcon != null) ...[
                          const SizedBox(width: 8),
                          Icon(trailingIcon, color: iconColor, size: 20),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            }),
            const Spacer(),
            if (_answered)
              ElevatedButton(
                onPressed: _next,
                child: Text(
                  _currentIndex + 1 < widget.questions.length
                      ? 'Next'
                      : 'Finish',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
