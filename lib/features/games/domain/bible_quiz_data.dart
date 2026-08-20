/// One quiz question: a verse with 1-3 words replaced by blanks, plus
/// the correct words (in blank order) and a handful of decoy words to
/// mix into the tappable word bank.
///
/// Fully static/local — no network, no Groq call, matching the app's
/// offline-first design and giving predictable, curated content rather
/// than AI-generated questions that could misquote scripture.
class BibleQuizQuestion {
  const BibleQuizQuestion({
    required this.reference,
    required this.template,
    required this.answers,
    required this.decoys,
  });

  final String reference;

  /// The verse text with each blank written as `{0}`, `{1}`, etc., in
  /// the order they should be filled.
  final String template;

  /// Correct words, in blank order — answers[0] fills {0}, etc.
  final List<String> answers;

  /// Extra words mixed into the word bank alongside the correct answers
  /// to make the choice meaningful rather than "tap the only word left."
  final List<String> decoys;
}

const List<BibleQuizQuestion> kBibleQuizQuestions = [
  BibleQuizQuestion(
    reference: 'John 3:16',
    template:
        'For God so {0} the world, that he gave his only begotten {1}, '
        'that whosoever believeth in him should not perish, but have '
        'everlasting {2}.',
    answers: ['loved', 'Son', 'life'],
    decoys: ['liked', 'Daughter', 'death', 'joy'],
  ),
  BibleQuizQuestion(
    reference: 'Philippians 4:13',
    template: 'I can do all things through {0} which strengtheneth me.',
    answers: ['Christ'],
    decoys: ['faith', 'prayer', 'hope'],
  ),
  BibleQuizQuestion(
    reference: 'Psalm 23:1',
    template: 'The LORD is my {0}; I shall not {1}.',
    answers: ['shepherd', 'want'],
    decoys: ['guide', 'fear', 'fall'],
  ),
  BibleQuizQuestion(
    reference: 'Romans 8:28',
    template:
        'And we know that all things work together for {0} to them that '
        'love God, to them who are the called according to his {1}.',
    answers: ['good', 'purpose'],
    decoys: ['ill', 'glory', 'plan'],
  ),
  BibleQuizQuestion(
    reference: 'Proverbs 3:5',
    template:
        'Trust in the LORD with all thine {0}; and lean not unto thine '
        'own {1}.',
    answers: ['heart', 'understanding'],
    decoys: ['soul', 'wisdom', 'strength'],
  ),
  BibleQuizQuestion(
    reference: 'Joshua 1:9',
    template:
        'Have not I commanded thee? Be strong and of a good {0}; be not '
        'afraid, neither be thou {1}.',
    answers: ['courage', 'dismayed'],
    decoys: ['heart', 'discouraged', 'silent'],
  ),
  BibleQuizQuestion(
    reference: 'Genesis 1:1',
    template: 'In the beginning God created the {0} and the {1}.',
    answers: ['heaven', 'earth'],
    decoys: ['stars', 'sea', 'light'],
  ),
  BibleQuizQuestion(
    reference: 'Romans 6:5',
    template:
        'For if we have been planted together in the {0} of his death, we '
        'shall be also in the likeness of his {1}:',
    answers: ['likeness', 'resurrection'],
    decoys: ['image', 'death', 'glory'],
  ),
  BibleQuizQuestion(
    reference: 'Matthew 6:33',
    template:
        'But seek ye first the kingdom of God, and his {0}; and all these '
        'things shall be added unto you.',
    answers: ['righteousness'],
    decoys: ['glory', 'mercy', 'wisdom'],
  ),
  BibleQuizQuestion(
    reference: 'Isaiah 40:31',
    template:
        'But they that wait upon the LORD shall renew their {0}; they '
        'shall mount up with wings as eagles.',
    answers: ['strength'],
    decoys: ['hope', 'faith', 'joy'],
  ),
  BibleQuizQuestion(
    reference: '1 Corinthians 13:13',
    template:
        'And now abideth faith, hope, {0}, these three; but the greatest '
        'of these is {1}.',
    answers: ['charity', 'charity'],
    decoys: ['love', 'grace', 'peace'],
  ),
  BibleQuizQuestion(
    reference: 'Jeremiah 29:11',
    template:
        'For I know the thoughts that I think toward you, saith the '
        'LORD, thoughts of {0}, and not of evil, to give you an expected '
        '{1}.',
    answers: ['peace', 'end'],
    decoys: ['harm', 'sorrow', 'beginning'],
  ),
  BibleQuizQuestion(
    reference: 'Ephesians 2:8',
    template:
        'For by grace are ye saved through {0}; and that not of '
        'yourselves: it is the gift of {1}:',
    answers: ['faith', 'God'],
    decoys: ['works', 'man', 'love'],
  ),
  BibleQuizQuestion(
    reference: 'Psalm 46:1',
    template:
        'God is our refuge and {0}, a very present help in {1}.',
    answers: ['strength', 'trouble'],
    decoys: ['shield', 'peace', 'need'],
  ),
  BibleQuizQuestion(
    reference: 'Matthew 28:19',
    template:
        'Go ye therefore, and teach all nations, baptizing them in the '
        'name of the Father, and of the {0}, and of the Holy {1}:',
    answers: ['Son', 'Ghost'],
    decoys: ['Lamb', 'Spirit', 'Word'],
  ),
];
