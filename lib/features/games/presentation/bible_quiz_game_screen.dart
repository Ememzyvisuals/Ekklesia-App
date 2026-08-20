import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/config/app_theme.dart';
import '../domain/bible_quiz_data.dart';

/// A native Flutter mini-game (no WebView, no import, no URL) — Bible
/// verses with key words blanked out, filled by tapping word tiles from
/// a shuffled bank (mixing correct answers with decoy words), across a
/// fixed round of questions with a running score shown at the end.
///
/// Reachable from both Home's category grid and the Games tab (see
/// home_screen.dart / games_screen.dart) — the same screen either way,
/// not two separate implementations.
class BibleQuizGameScreen extends StatefulWidget {
  const BibleQuizGameScreen({super.key});

  @override
  State<BibleQuizGameScreen> createState() => _BibleQuizGameScreenState();
}

class _BibleQuizGameScreenState extends State<BibleQuizGameScreen> {
  static const _questionsPerRound = 8;

  late final List<BibleQuizQuestion> _round;
  int _questionIndex = 0;
  int _score = 0;
  bool _finished = false;

  // Per-question state
  late List<String?> _filledBlanks; // null = still empty
  late List<String> _wordBank; // remaining unplaced tiles, shuffled
  bool _questionLocked = false; // true once all blanks filled, showing result

  final _random = Random();

  @override
  void initState() {
    super.initState();
    final pool = List<BibleQuizQuestion>.from(kBibleQuizQuestions)
      ..shuffle(_random);
    _round = pool.take(_questionsPerRound).toList();
    _setUpQuestion();
  }

  void _setUpQuestion() {
    final q = _round[_questionIndex];
    _filledBlanks = List<String?>.filled(q.answers.length, null);
    _wordBank = [...q.answers, ...q.decoys]..shuffle(_random);
    _questionLocked = false;
  }

  void _tapWord(String word) {
    if (_questionLocked) return;
    final nextEmptyIndex = _filledBlanks.indexOf(null);
    if (nextEmptyIndex == -1) return; // no empty blank left, ignore tap
    setState(() {
      _filledBlanks[nextEmptyIndex] = word;
      _wordBank.remove(word);
    });
    if (!_filledBlanks.contains(null)) {
      _checkAnswer();
    }
  }

  void _undoLast(int blankIndex) {
    if (_questionLocked) return;
    final word = _filledBlanks[blankIndex];
    if (word == null) return;
    setState(() {
      _filledBlanks[blankIndex] = null;
      _wordBank.add(word);
    });
  }

  void _checkAnswer() {
    final q = _round[_questionIndex];
    final correct = List.generate(
            q.answers.length, (i) => _filledBlanks[i] == q.answers[i])
        .every((ok) => ok);
    setState(() {
      _questionLocked = true;
      if (correct) _score++;
    });
  }

  void _nextQuestion() {
    if (_questionIndex + 1 >= _round.length) {
      setState(() => _finished = true);
      return;
    }
    setState(() {
      _questionIndex++;
      _setUpQuestion();
    });
  }

  void _restart() {
    setState(() {
      final pool = List<BibleQuizQuestion>.from(kBibleQuizQuestions)
        ..shuffle(_random);
      _round.clear();
      _round.addAll(pool.take(_questionsPerRound));
      _questionIndex = 0;
      _score = 0;
      _finished = false;
      _setUpQuestion();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bible Quiz'),
        actions: [
          if (!_finished)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  '${_questionIndex + 1}/${_round.length}  \u00b7  Score $_score',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
      body: _finished ? _buildResults(context) : _buildQuestion(context),
    );
  }

  Widget _buildResults(BuildContext context) {
    final total = _round.length;
    final pct = (_score / total * 100).round();
    final message = pct >= 80
        ? 'Excellent! You know your Bible well.'
        : pct >= 50
            ? 'Good effort. Keep reading and try again.'
            : 'Keep studying. You will do better next time.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.emoji_events,
                size: 56,
                color: pct >= 80
                    ? AppColors.accent
                    : AppTheme.textSecondary(context)),
            const SizedBox(height: 16),
            Text(
              '$_score / $total',
              style:
                  const TextStyle(fontSize: 40, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textSecondary(context))),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _restart,
              icon: const Icon(Icons.replay),
              label: const Text('Play Again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuestion(BuildContext context) {
    final q = _round[_questionIndex];
    final parts = q.template.split(RegExp(r'\{\d\}'));
    // Extract blank indices in order of appearance in the template, so
    // rendering can interleave literal text parts with blank slots.
    final blankMatches = RegExp(r'\{(\d)\}')
        .allMatches(q.template)
        .map((m) => int.parse(m.group(1)!))
        .toList();
    final allCorrect = !_filledBlanks.contains(null) &&
        _filledBlanks
            .asMap()
            .entries
            .every((e) => e.value == q.answers[e.key]);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(q.reference,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 16),
          // The verse with blanks — built as a Wrap of literal-text spans
          // and tappable blank chips, rather than RichText, since a
          // blank needs to be its own tappable/undo-able widget, not
          // just styled text.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < parts.length; i++) ...[
                Text(parts[i],
                    style: const TextStyle(fontSize: 17, height: 1.6)),
                if (i < blankMatches.length)
                  _BlankChip(
                    word: _filledBlanks[blankMatches[i]],
                    locked: _questionLocked,
                    onTap: () => _undoLast(blankMatches[i]),
                  ),
              ],
            ],
          ),
          const SizedBox(height: 24),
          if (_questionLocked) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: allCorrect
                    ? Colors.green.withValues(alpha: 0.15)
                    : Colors.red.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    allCorrect ? Icons.check_circle : Icons.cancel,
                    color: allCorrect ? Colors.green : Colors.red,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(allCorrect
                        ? 'Correct!'
                        : 'Correct answer: ${q.answers.join(', ')}'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _nextQuestion,
              child: Text(_questionIndex + 1 >= _round.length
                  ? 'See Results'
                  : 'Next Question'),
            ),
          ] else ...[
            Text('Tap a word to fill the next blank',
                style: TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary(context))),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _wordBank
                  .map((w) => _WordTile(word: w, onTap: () => _tapWord(w)))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _BlankChip extends StatelessWidget {
  const _BlankChip(
      {required this.word, required this.locked, required this.onTap});

  final String? word;
  final bool locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: (word != null && !locked) ? onTap : null,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: word == null
                ? AppTheme.surface(context)
                : AppColors.accent.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: word == null
                    ? AppTheme.textSecondary(context).withValues(alpha: 0.4)
                    : AppColors.accent),
          ),
          constraints: const BoxConstraints(minWidth: 60),
          child: Text(
            word ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

class _WordTile extends StatelessWidget {
  const _WordTile({required this.word, required this.onTap});

  final String word;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface(context),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border:
                Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
          ),
          child: Text(word, style: const TextStyle(fontSize: 15)),
        ),
      ),
    );
  }
}
