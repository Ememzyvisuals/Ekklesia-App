import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show PlayerState, ProcessingState;

import '../../../core/config/app_theme.dart';
import '../../../core/config/app_config.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../bookmarks/presentation/bookmark_button.dart';
import '../../bookmarks/domain/bookmark_item.dart';
import '../../../core/database/app_database.dart';
import '../data/bible_providers.dart';
import '../data/bible_repository.dart';
import '../data/audio_bible_service.dart';
import '../data/audio_bible_book_slugs.dart';
import '../../../core/widgets/ekklesia_companion.dart';
import '../../../core/services/app_settings_service.dart';

enum _View { books, chapters, verses }

/// Offline Bible reader — reads from the local database populated by
/// [BibleImporter], not from any network API.
///
/// Scope note (honest, as of this pass): book/chapter navigation, verse
/// list, reference jump, offline substring search, bookmarking, verse
/// highlights (colored), verse notes, "Continue Reading," reading streak,
/// and localization (en/yo/ha/ig/pcm) are implemented. Chapter listen was
/// TTS-based (via TtsService/AudioService) and has been removed entirely
/// — see pubspec.yaml's removal notes — in favor of downloading
/// pre-recorded audio Bible chapters instead (audio_bible/ at the repo
/// root has the packaging pipeline; wiring actual playback into this
/// screen is a separate, not-yet-done pass).
/// NOT yet implemented: dedicated background workers (BibleSyncWorker
/// etc. — general housekeeping is folded into the existing
/// CleanupWorker instead, see its doc comment).
class BibleScreen extends ConsumerStatefulWidget {
  const BibleScreen({super.key, this.initialReference, this.initialLanguage});

  /// Set when arriving from a search result or bookmark tap — jumps
  /// straight to that reference's chapter and, if it includes a verse
  /// number (e.g. "John 3:16" vs. just "Genesis 1"), scrolls to and
  /// blinks that specific verse. Was previously ignored entirely: both
  /// search and bookmarks just opened a bare BibleScreen with no
  /// reference at all, landing on whatever was last read (or Genesis 1)
  /// regardless of what was actually tapped.
  final String? initialReference;

  /// Overrides the Bible language for this one open — used by bookmarks,
  /// which remember which language a reference was bookmarked in.
  final String? initialLanguage;

  @override
  ConsumerState<BibleScreen> createState() => _BibleScreenState();
}

class _BibleScreenState extends ConsumerState<BibleScreen> {
  _View _view = _View.books;
  BibleBook? _selectedBook;
  int? _selectedChapter;
  List<BibleVerse> _verses = [];
  final _referenceController = TextEditingController();
  // _searchController/_searchResults/_searching REMOVED — search now
  // lives entirely inside _BibleSearchSheet (its own local state),
  // reached via the app bar's search icon (_openSearchSheet).
  bool _loadingVerses = false;
  String? _error;
  // Holds the real, unfiltered exception text behind a friendly error —
  // set alongside `_error` for unexpected failure paths (Bible import,
  // chapter loading, etc.) so a real error is one tap away via
  // "Details" instead of permanently invisible.
  String? _errorDetail;
  Map<int, Highlight> _highlights = {};

  // Audio Bible playback state (pre-recorded downloads — replaces TTS
  // entirely, see pubspec.yaml's removal notes). Tracked per-screen
  // rather than read live from AudioBibleService everywhere, since a
  // few different widgets (floating button, bottom sheet) need to
  // rebuild together on the same state changes.
  bool _audioDownloading = false;
  bool _audioPlaying = false;
  AudioBibleDownloadProgress? _audioDownloadProgress;
  StreamSubscription<PlayerState>? _audioStateSub;
  StreamSubscription<AudioBibleDownloadProgress?>? _audioProgressSub;

  // Verse-jump-and-blink support: one GlobalKey per rendered verse (so
  // Scrollable.ensureVisible can find it), which verse is currently
  // blinking, and whether the blink is in its "on" phase right now.
  final Map<int, GlobalKey> _verseKeys = {};
  int? _blinkVerseNumber;
  bool _blinkVisible = false;
  Timer? _blinkTimer;

  // Named swatches, not emoji — every one of these renders as a plain
  // solid-color circle (see _showVerseActions), never a pictograph.
  static const Map<String, Color> _highlightPalette = {
    'Yellow': Color(0xFFFFEB3B),
    'Green': Color(0xFFA5D6A7),
    'Blue': Color(0xFF90CAF9),
    'Pink': Color(0xFFF48FB1),
  };

  static const _transitionDuration = Duration(milliseconds: 260);

  String get _bibleLanguage => ref.read(bibleLanguageProvider);

  /// Toggles audio Bible playback for the CURRENTLY VIEWED chapter —
  /// downloads it first if needed. If something is already playing
  /// (this chapter or otherwise), toggles pause/resume on that instead
  /// of starting a second, overlapping playback — there's only ever one
  /// "now playing" audio, matching a normal player's behavior.
  Future<void> _toggleAudioPlayback() async {
    if (_audioPlaying) {
      await AudioBibleService.instance.pause();
      return;
    }

    final playerState = AudioBibleService.instance.player.processingState;
    final hasPausedAudio = playerState != ProcessingState.idle &&
        playerState != ProcessingState.completed;
    if (hasPausedAudio) {
      // Paused mid-chapter — resume the same audio rather than
      // re-downloading/restarting from verse 1.
      await AudioBibleService.instance.resume();
      return;
    }

    final book = _selectedBook;
    final chapter = _selectedChapter;
    if (book == null || chapter == null) return;

    setState(() {
      _error = null;
      _errorDetail = null;
    });

    try {
      await AudioBibleService.instance
          .playChapter(_bibleLanguage, book.position, chapter);
    } on AudioBibleUnavailableException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not play this chapter\'s audio. Try again.';
        _errorDetail = e.toString();
      });
    }
  }


  Future<void> _openChapter(BibleBook book, int chapterNumber) async {
    setState(() {
      _loadingVerses = true;
      _error = null;
      // GlobalKeys are per-verse-number, and verse numbers reset every
      // chapter (chapter 2 also has a "verse 5") — stale keys pointing
      // at the previous chapter's now-unmounted widgets would make
      // Scrollable.ensureVisible fail silently or scroll to the wrong
      // place.
      _verseKeys.clear();
    });
    try {
      final repo = ref.read(bibleRepositoryProvider);
      final annotations = ref.read(bibleAnnotationsRepositoryProvider);
      final verses =
          await repo.getVerses(_bibleLanguage, book.code, chapterNumber);
      final highlights = await annotations.getHighlightsForChapter(
          _bibleLanguage, book.code, chapterNumber);
      setState(() {
        _selectedBook = book;
        _selectedChapter = chapterNumber;
        _verses = verses;
        _highlights = highlights;
        _view = _View.verses;
      });
      // Fire-and-forget — "Continue Reading" and the streak counter are
      // conveniences, not critical-path; a failed write here shouldn't
      // block reading.
      unawaited(
        annotations.saveProgress(
          language: _bibleLanguage,
          bookCode: book.code,
          bookName: book.name,
          chapter: chapterNumber,
        ),
      );
      unawaited(annotations.recordReadingActivity());
    } catch (_) {
      // Same raw-exception-dump bug found and fixed elsewhere in this
      // file/session — a local read failure here, so a generic message
      // covers every real cause.
      setState(
          () => _error = 'Could not open that chapter. Try again.');
    } finally {
      setState(() => _loadingVerses = false);
    }
  }

  Future<void> _jumpToReference() async {
    final raw = _referenceController.text.trim();
    if (raw.isEmpty) {
      return;
    }
    setState(() {
      _loadingVerses = true;
      _error = null;
    });
    try {
      final repo = ref.read(bibleRepositoryProvider);
      final parsed = parseBibleReference(raw);
      final books = await repo.getBooks(_bibleLanguage);
      final book = books.firstWhere(
        (b) => b.code == parsed.book.code,
        orElse: () => throw BibleReferenceException(
          '${parsed.book.englishName} not found. Is this language imported?',
        ),
      );
      await _openChapter(book, parsed.chapter);
      // Only chapter-and-verse references (e.g. "John 3:16") get the
      // scroll+blink treatment — a bare chapter reference ("Genesis 1")
      // has no specific verse to point at, so just landing on the
      // chapter itself (already done by _openChapter above) is correct.
      if (parsed.startVerse != null && mounted) {
        _scrollToAndBlinkVerse(parsed.startVerse!);
      }
    } catch (e) {
      setState(() {
        // BibleReferenceException carries its own clear message (e.g.
        // "Genesis not found. Is this language imported?") — worth
        // keeping, just stripped of the raw "BibleReferenceException:"
        // type prefix. Anything else falls back to a generic message
        // rather than whatever raw exception text came through.
        _error = e is BibleReferenceException
            ? e.message
            : 'Could not find that reference. Check the spelling and try again.';
        _loadingVerses = false;
      });
    }
  }

  /// Scrolls the verse list to [verseNumber] and blinks it 3 times —
  /// the explicit request: "there should be a highlight that will be
  /// blinking... to show me this is where you have referred to."
  /// Waits a frame after the verse list itself renders (GlobalKeys
  /// aren't attached to a RenderObject until then) before scrolling.
  void _scrollToAndBlinkVerse(int verseNumber) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final key = _verseKeys[verseNumber];
      final targetContext = key?.currentContext;
      if (targetContext != null) {
        await Scrollable.ensureVisible(
          targetContext,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          alignment:
              0.3, // lands roughly a third down the screen, not glued to the very top
        );
      }
      if (!mounted) return;

      _blinkTimer?.cancel();
      setState(() {
        _blinkVerseNumber = verseNumber;
        _blinkVisible = true;
      });
      var toggleCount = 0;
      const totalToggles = 6; // 3 full on/off blinks
      _blinkTimer = Timer.periodic(const Duration(milliseconds: 350), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        toggleCount++;
        if (toggleCount >= totalToggles) {
          timer.cancel();
          setState(() {
            _blinkVerseNumber = null;
            _blinkVisible = false;
          });
          return;
        }
        setState(() => _blinkVisible = !_blinkVisible);
      });
    });
  }

  // _runSearch REMOVED — search logic now lives inside _BibleSearchSheet
  // (its own local state), not on this screen.

  /// Shows the real underlying exception text in a selectable dialog —
  /// so a real failure can actually be read and copied (to report back,
  /// paste into a message, etc.) instead of the friendly message above
  /// being the only thing anyone ever sees, which made every distinct
  /// real failure indistinguishable from every other one.
  void _showErrorDetail(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Error details'),
        content: SingleChildScrollView(
          child: SelectableText(
              '${_errorDetail ?? ''}\n\n(build: ${AppConfig.buildTag})'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Color _colorFromHex(String hex) => Color(int.parse(hex, radix: 16));

  void _copyVerse(BibleVerse v) {
    if (v.content == null) {
      return;
    }
    final refText = '${_selectedBook?.name ?? ''} ${v.chapter}:${v.number}';
    Clipboard.setData(ClipboardData(text: '$refText: ${v.content}'));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).bibleVerseCopied)),
    );
  }

  @override
  void initState() {
    super.initState();
    // Reflects AudioBibleService's actual player/download state into
    // this screen's own state so the floating button and bottom sheet
    // (built below) rebuild live — the service itself is a singleton
    // shared across the whole app, not owned by this screen.
    _audioStateSub = AudioBibleService.instance.stateStream.listen((state) {
      if (!mounted) return;
      setState(() => _audioPlaying = state.playing);
    });
    _audioProgressSub =
        AudioBibleService.instance.downloadProgressStream.listen((progress) {
      if (!mounted) return;
      setState(() {
        _audioDownloadProgress = progress;
        _audioDownloading = progress != null;
      });
    });
    if (widget.initialLanguage != null) {
      // Set once here, before the first frame — bibleLanguageProvider is
      // a StateProvider, safe to write in initState via ref.read (not
      // ref.watch, which initState can't use).
      Future.microtask(() {
        if (mounted) {
          ref.read(bibleLanguageProvider.notifier).state =
              widget.initialLanguage!;
        }
      });
    }
    if (widget.initialReference != null &&
        widget.initialReference!.trim().isNotEmpty) {
      _referenceController.text = widget.initialReference!;
      // Runs after the first frame so bibleLanguageProvider (possibly
      // just set above) and the book list are ready.
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToReference());
    }
  }

  @override
  void dispose() {
    _audioStateSub?.cancel();
    _audioProgressSub?.cancel();
    _blinkTimer?.cancel();
    _referenceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bibleLanguage = ref.watch(bibleLanguageProvider);
    final importStatus = ref.watch(bibleImportStatusProvider(bibleLanguage));

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navBible),
        leading: AnimatedSwitcher(
          duration: _transitionDuration,
          child: _view == _View.books
              ? const SizedBox.shrink(key: ValueKey('no-back'))
              : IconButton(
                  key: const ValueKey('back'),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded),
                  onPressed: () => setState(() {
                    _view =
                        _view == _View.verses ? _View.chapters : _View.books;
                  }),
                ),
        ),
        actions: [
          // Font-size control — the specific, named request was making
          // the Bible easier to read for older users. Placed here
          // rather than only in Settings since this is the screen it
          // actually matters for; Settings also gets a quick entry for
          // people who'd rather find it there.
          IconButton(
            icon: const Text('Aa', style: TextStyle(fontWeight: FontWeight.bold)),
            tooltip: 'Text size',
            onPressed: () => _showFontSizeSheet(context),
          ),
          // Search — was two always-visible text fields (a reference
          // jump box and a live-search box) sitting permanently at the
          // top of the reading screen, explicitly reported as making
          // the Bible itself "not visible enough." Collapsed into one
          // icon that opens a full search overlay on demand instead,
          // matching the reference screenshots (a plain magnifying-
          // glass icon that reveals a dedicated search screen, rather
          // than reserving space for search at all times).
          IconButton(
            icon: const Icon(Icons.search_rounded),
            tooltip: l10n.bibleSearchHint,
            onPressed: () => _openSearchSheet(bibleLanguage),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: bibleLanguage,
              borderRadius: BorderRadius.circular(12),
              dropdownColor: AppTheme.surface(context),
              items: kBibleCodeLabel.entries
                  .map((e) => DropdownMenuItem(
                        value: e.key,
                        child: Text(
                          e.value,
                          style:
                              TextStyle(color: AppTheme.textPrimary(context)),
                        ),
                      ))
                  .toList(),
              onChanged: (code) {
                if (code == null) {
                  return;
                }
                ref.read(bibleLanguageProvider.notifier).state = code;
                setState(() {
                  _view = _View.books;
                  _selectedBook = null;
                  _selectedChapter = null;
                  _verses = [];
                });
              },
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: importStatus.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            Center(child: Text('${l10n.bibleErrorCheckingImport}: $e')),
        data: (imported) {
          return AnimatedSwitcher(
            duration: _transitionDuration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: child,
            ),
            child: imported
                ? _buildReader(bibleLanguage, key: const ValueKey('reader'))
                : _AutoImportingView(
                    key: const ValueKey('importing'),
                    bibleLanguage: bibleLanguage,
                  ),
          );
        },
      ),
    );
  }

  Widget _buildReader(String bibleLanguage, {Key? key}) {
    return Column(
      key: key,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: _error != null
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!,
                          style: const TextStyle(color: Colors.red)),
                      if (_errorDetail != null)
                        InkWell(
                          onTap: () => _showErrorDetail(context),
                          child: const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Text('Details',
                                style: TextStyle(
                                    color: Colors.red,
                                    decoration: TextDecoration.underline,
                                    fontSize: 12)),
                          ),
                        ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        Expanded(child: _buildNavigation(bibleLanguage)),
      ],
    );
  }

  /// Opens the search overlay — was two always-visible text fields
  /// permanently occupying the top of the reading screen; explicitly
  /// reported as making the Bible itself "not visible enough."
  /// Collapsed into this on-demand sheet instead, matching the
  /// reference screenshots (a search icon reveals a dedicated search
  /// screen with quick suggestions, rather than reserving space for
  /// search at all times). Selecting a suggestion or a result closes
  /// the sheet and jumps straight to that passage — no more results
  /// staying open inline atop the reading view.
  void _openSearchSheet(String bibleLanguage) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _BibleSearchSheet(
        bibleLanguage: bibleLanguage,
        onJumpToReference: (reference) {
          Navigator.of(sheetContext).pop();
          _referenceController.text = reference;
          _jumpToReference();
        },
        onSelectVerse: (verse) async {
          Navigator.of(sheetContext).pop();
          final repo = ref.read(bibleRepositoryProvider);
          final books = await repo.getBooks(bibleLanguage);
          final book = books.firstWhere((b) => b.code == verse.bookCode);
          await _openChapter(book, verse.chapter);
        },
      ),
    );
  }

  // _buildSearchResults REMOVED — search now happens entirely within
  // the _BibleSearchSheet overlay (see _openSearchSheet above), not
  // inline within the main reading view.

  Future<void> _continueReading(String bookCode, int chapter) async {
    final repo = ref.read(bibleRepositoryProvider);
    final books = await repo.getBooks(_bibleLanguage);
    final book =
        books.firstWhere((b) => b.code == bookCode, orElse: () => books.first);
    await _openChapter(book, chapter);
  }

  Widget _buildNavigation(String bibleLanguage) {
    late final Widget child;
    switch (_view) {
      case _View.books:
        child = _BookList(
          key: const ValueKey('books'),
          bibleLanguage: bibleLanguage,
          onSelect: (book) => setState(() {
            _selectedBook = book;
            _view = _View.chapters;
          }),
          onContinueReading: _continueReading,
        );
        break;
      case _View.chapters:
        final book = _selectedBook;
        child = book == null
            ? const SizedBox.shrink(key: ValueKey('chapters-empty'))
            : _ChapterGrid(
                key: ValueKey('chapters-${book.code}'),
                book: book,
                onSelect: (chapterNumber) => _openChapter(book, chapterNumber),
              );
        break;
      case _View.verses:
        child = KeyedSubtree(
          key: ValueKey('verses-${_selectedBook?.code}-$_selectedChapter'),
          child: _buildVerseList(),
        );
        break;
    }

    // A gentle iOS-style push: new screen fades and slides in slightly
    // from the right, old one fades out — not a bounce, not a flip, just
    // enough motion to signal "you moved forward," matching the depth of
    // animation elsewhere in the app.
    return AnimatedSwitcher(
      duration: _transitionDuration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final offset =
            Tween<Offset>(begin: const Offset(0.04, 0), end: Offset.zero)
                .animate(animation);
        return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: offset, child: child));
      },
      child: child,
    );
  }

  Widget _buildVerseList() {
    final l10n = AppLocalizations.of(context);
    if (_loadingVerses) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_selectedBook == null || _selectedChapter == null) {
      return const SizedBox.shrink();
    }
    final book = _selectedBook!;
    final chapter = _selectedChapter!;
    final hasNextChapter = chapter < book.chapterCount;

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Compact utility row — search/settings-style icon buttons
            // instead of the old header eating a full text-label row; the
            // book/chapter identity now lives in the big centered header
            // below, matching how a real Bible app (see the reference
            // screenshots) keeps chrome quiet and lets the chapter number
            // itself be the visual anchor.
            // The big centered header — small caps book name, then a huge
            // chapter number as the actual visual anchor of the screen.
            // This is the single biggest change from the old plain-text
            // layout: a Bible reading screen should feel like a real book
            // you're opening to a specific page, not a scrolling text log.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
              child: Column(
                children: [
                  Text(
                    book.name.toUpperCase(),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 2.2,
                      color: AppTheme.textSecondary(context),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$chapter',
                    style: TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 64,
                      fontWeight: FontWeight.w700,
                      height: 1.0,
                      color: AppTheme.textPrimary(context),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                // +1 for the "next chapter" pill at the end — a real Bible
                // app lets you keep reading forward without backing out to
                // the chapter grid every time (see the reference
                // screenshots' bottom "Job 32" pill).
                itemCount: _verses.length + 1,
                itemBuilder: (context, i) {
                  if (i == _verses.length) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Center(
                        child: hasNextChapter
                            ? OutlinedButton.icon(
                                onPressed: () =>
                                    _openChapter(book, chapter + 1),
                                icon: const Icon(Icons.arrow_forward_rounded,
                                    size: 18),
                                label: Text('${book.name} ${chapter + 1}'),
                              )
                            : Text(
                                "That's the end of ${book.name}.",
                                style: TextStyle(
                                    color: AppTheme.textSecondary(context)),
                              ),
                      ),
                    );
                  }
                  final v = _verses[i];
                  if (v.omitted) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        '${v.number}. [${l10n.bibleNotIncluded}]',
                        style: TextStyle(
                            color: AppTheme.textSecondary(context),
                            fontStyle: FontStyle.italic),
                      ),
                    );
                  }
                  final isBlinking =
                      _blinkVerseNumber == v.number && _blinkVisible;
                  final highlightColor = isBlinking
                      ? AppColors.accent.withValues(alpha: 0.55)
                      : _highlights[v.number] != null
                          ? _colorFromHex(_highlights[v.number]!.colorHex)
                              .withValues(alpha: 0.35)
                          : Colors.transparent;
                  final verseKey =
                      _verseKeys.putIfAbsent(v.number, () => GlobalKey());
                  return InkWell(
                    key: verseKey,
                    onLongPress: () => _showVerseActions(v),
                    borderRadius: BorderRadius.circular(6),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: double.infinity,
                      color: highlightColor,
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: RichText(
                        // RichText, unlike Text, does NOT automatically pick
                        // up ambient text scaling from MediaQuery — it needs
                        // textScaler passed explicitly. Without this line,
                        // the font-size preference wired into MaterialApp's
                        // builder in main.dart would silently have no effect
                        // here specifically, which would have been a real
                        // problem given the Bible reader is the actual,
                        // named reason that setting exists.
                        textScaler: MediaQuery.textScalerOf(context),
                        text: TextSpan(
                          // Serves the same "elegant reading" role as a
                          // reference Bible app's serif body text — Outfit
                          // is this app's one bundled font (see
                          // app_theme.dart), used here at a larger size and
                          // taller line-height than the rest of the UI
                          // specifically for long-form reading comfort,
                          // rather than introducing a second typeface.
                          style: TextStyle(
                            fontFamily: 'Outfit',
                            fontSize: 17,
                            height: 1.65,
                            color: AppTheme.textPrimary(context),
                          ),
                          children: [
                            // Small, raised-by-size-contrast verse number —
                            // reads as a superscript against the much larger
                            // body text beside it, the same visual trick a
                            // printed Bible uses, without needing manual
                            // baseline offset hacks.
                            TextSpan(
                              text: '${v.number} ',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textSecondary(context),
                              ),
                            ),
                            TextSpan(text: v.content ?? ''),
                            if (v.approximate)
                              TextSpan(
                                text: '  (${l10n.bibleApproxNumbering})',
                                style: const TextStyle(
                                    fontSize: 11, fontStyle: FontStyle.italic),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        // Floating audio-Bible control — replaces the old inline "Listen"
        // button (TTS-based, removed entirely, see pubspec.yaml's removal
        // notes). Floating rather than blocking, per the explicit request:
        // a person can keep reading the verse text underneath while
        // audio plays, matching the reference screenshots' small
        // circular control docked to the side of the screen rather than
        // a modal player.
        if (kAudioBibleAvailableLanguages.contains(_bibleLanguage))
          Positioned(
            right: 16,
            bottom: 24,
            child: _AudioBibleFloatingButton(
              playing: _audioPlaying,
              downloading: _audioDownloading,
              downloadProgress: _audioDownloadProgress,
              onTap: _toggleAudioPlayback,
              onLongPress: () => _openAudioPlayerSheet(book, chapter),
            ),
          ),
      ],
    );
  }

  void _openAudioPlayerSheet(BibleBook book, int chapter) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _AudioBiblePlayerSheet(
        bookName: book.name,
        chapterNumber: chapter,
        onTogglePlayback: _toggleAudioPlayback,
        playing: _audioPlaying,
      ),
    );
  }

  void _showFontSizeSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => Consumer(
        builder: (sheetContext, ref, _) {
          final scale = ref.watch(fontScaleProvider);
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Text size',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                        color: AppTheme.textPrimary(sheetContext))),
                const SizedBox(height: 4),
                Text(
                  'Applies across the whole app, not just the Bible.',
                  style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary(sheetContext)),
                ),
                const SizedBox(height: 16),
                // A live preview line, scaled the same way the actual
                // Bible text is (Text picks up ambient MediaQuery
                // scaling automatically) — so the effect is visible
                // immediately, before closing the sheet.
                Text(
                  'In the beginning God created the heaven and the earth.',
                  style: TextStyle(
                      fontFamily: 'Outfit',
                      color: AppTheme.textPrimary(sheetContext)),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('A', style: TextStyle(fontSize: 14)),
                    Expanded(
                      child: Slider(
                        value: scale,
                        min: AppSettingsService.minFontScale,
                        max: AppSettingsService.maxFontScale,
                        divisions: 15,
                        label: '${(scale * 100).round()}%',
                        onChanged: (value) => ref
                            .read(fontScaleProvider.notifier)
                            .setScale(value),
                      ),
                    ),
                    const Text('A', style: TextStyle(fontSize: 24)),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showVerseActions(BibleVerse v) {
    final l10n = AppLocalizations.of(context);
    final refLabel = '${_selectedBook?.name ?? ''} ${v.chapter}:${v.number}';
    final isHighlighted = _highlights[v.number] != null;
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: Text(l10n.bibleCopyVerse),
              onTap: () {
                Navigator.pop(context);
                _copyVerse(v);
              },
            ),
            ListTile(
              leading: const Icon(Icons.bookmark_border_rounded),
              title: Text(l10n.bibleBookmarkAction),
              trailing: BookmarkButton(
                key: ValueKey('${v.bookCode}-${v.chapter}-${v.number}'),
                type: BookmarkType.bible,
                refId: refLabel,
                title: refLabel,
                subtitle: v.content ?? '',
                language: ref.read(bibleLanguageProvider),
              ),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: Icon(
                Icons.brush_rounded,
                color: isHighlighted
                    ? _colorFromHex(_highlights[v.number]!.colorHex)
                    : null,
              ),
              title: Text(l10n.bibleHighlight),
              subtitle: Text(l10n.bibleHighlightHint),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 12,
                children: _highlightPalette.entries.map((entry) {
                  final selected = isHighlighted &&
                      _highlights[v.number]!.colorHex == _hexOf(entry.value);
                  return GestureDetector(
                    onTap: () async {
                      Navigator.pop(context);
                      final annotations =
                          ref.read(bibleAnnotationsRepositoryProvider);
                      if (selected) {
                        await annotations.removeHighlight(
                          language: _bibleLanguage,
                          bookCode: v.bookCode,
                          chapter: v.chapter,
                          verseNumber: v.number,
                        );
                      } else {
                        await annotations.setHighlight(
                          language: _bibleLanguage,
                          bookCode: v.bookCode,
                          chapter: v.chapter,
                          verseNumber: v.number,
                          colorHex: _hexOf(entry.value),
                        );
                      }
                      if (_selectedBook != null && _selectedChapter != null) {
                        final refreshed =
                            await annotations.getHighlightsForChapter(
                          _bibleLanguage,
                          _selectedBook!.code,
                          _selectedChapter!,
                        );
                        if (mounted) {
                          setState(() => _highlights = refreshed);
                        }
                      }
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOut,
                      width: selected ? 36 : 32,
                      height: selected ? 36 : 32,
                      decoration: BoxDecoration(
                        color: entry.value,
                        shape: BoxShape.circle,
                        border: selected
                            ? Border.all(color: Colors.black87, width: 2)
                            : null,
                      ),
                      child: selected
                          ? const Icon(Icons.check_rounded,
                              size: 16, color: Colors.black87)
                          : null,
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.edit_note_rounded),
              title: Text(l10n.bibleNote),
              onTap: () {
                Navigator.pop(context);
                _editNote(v);
              },
            ),
          ],
        ),
      ),
    );
  }

  String _hexOf(Color c) =>
      c.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0');

  Future<void> _editNote(BibleVerse v) async {
    final l10n = AppLocalizations.of(context);
    final annotations = ref.read(bibleAnnotationsRepositoryProvider);
    final existing = await annotations.getNote(
      language: _bibleLanguage,
      bookCode: v.bookCode,
      chapter: v.chapter,
      verseNumber: v.number,
    );
    final controller = TextEditingController(text: existing?.content ?? '');
    if (!mounted) {
      return;
    }
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
            '${l10n.bibleNote}: ${_selectedBook?.name ?? ''} ${v.chapter}:${v.number}'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          autofocus: true,
          decoration: InputDecoration(
              hintText: l10n.bibleNoteHint, border: const OutlineInputBorder()),
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.pop(context, ''),
              child: Text(l10n.commonDelete),
            ),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.commonCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(l10n.commonSave)),
        ],
      ),
    );
    if (result == null) {
      return;
    }
    await annotations.setNote(
      language: _bibleLanguage,
      bookCode: v.bookCode,
      chapter: v.chapter,
      verseNumber: v.number,
      text: result,
    );
  }
}

class _BookList extends ConsumerWidget {
  const _BookList(
      {super.key,
      required this.bibleLanguage,
      required this.onSelect,
      this.onContinueReading});
  final String bibleLanguage;
  final void Function(BibleBook) onSelect;
  final Future<void> Function(String bookCode, int chapter)? onContinueReading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final repo = ref.watch(bibleRepositoryProvider);
    final annotations = ref.watch(bibleAnnotationsRepositoryProvider);
    return FutureBuilder<List<BibleBook>>(
      future: repo.getBooks(bibleLanguage),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final books = snapshot.data!;
        final ot = books.where((b) => b.testament == 'OT').toList();
        final nt = books.where((b) => b.testament == 'NT').toList();
        return ListView(
          children: [
            FutureBuilder<ReadingStreakData>(
              future: annotations.getStreak(),
              builder: (context, streakSnapshot) {
                final streak = streakSnapshot.data;
                final show = streak != null && streak.currentStreak > 0;
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (child, anim) =>
                      FadeTransition(opacity: anim, child: child),
                  child: !show
                      ? const SizedBox.shrink(key: ValueKey('no-streak'))
                      : Padding(
                          key: const ValueKey('streak'),
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: Row(
                            children: [
                              const Icon(Icons.local_fire_department_rounded,
                                  color: Colors.deepOrange, size: 20),
                              const SizedBox(width: 6),
                              Text(
                                l10n.bibleStreakDays(streak.currentStreak) +
                                    (streak.longestStreak > streak.currentStreak
                                        ? ' (${l10n.bibleStreakBest(streak.longestStreak)})'
                                        : ''),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                );
              },
            ),
            if (onContinueReading != null)
              FutureBuilder<ReadingProgressData?>(
                future: annotations.getProgress(bibleLanguage),
                builder: (context, progressSnapshot) {
                  final progress = progressSnapshot.data;
                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    child: progress == null
                        ? const SizedBox.shrink(key: ValueKey('no-progress'))
                        : Card(
                            key: const ValueKey('progress'),
                            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                            child: ListTile(
                              leading: const Icon(Icons.menu_book_rounded),
                              title: Text(l10n.bibleContinueReading),
                              subtitle: Text(
                                  '${progress.bookName} ${progress.chapter}'),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () => onContinueReading!(
                                  progress.bookCode, progress.chapter),
                            ),
                          ),
                  );
                },
              ),
            _sectionHeader(l10n.bibleOldTestament),
            ...ot.map(
                (b) => ListTile(title: Text(b.name), onTap: () => onSelect(b))),
            _sectionHeader(l10n.bibleNewTestament),
            ...nt.map(
                (b) => ListTile(title: Text(b.name), onTap: () => onSelect(b))),
          ],
        );
      },
    );
  }

  Widget _sectionHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(label,
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: Colors.grey)),
      );
}

class _ChapterGrid extends StatelessWidget {
  const _ChapterGrid({super.key, required this.book, required this.onSelect});
  final BibleBook book;
  final void Function(int) onSelect;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: book.chapterCount,
      itemBuilder: (context, i) {
        final chapterNumber = i + 1;
        return OutlinedButton(
          style: OutlinedButton.styleFrom(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: () => onSelect(chapterNumber),
          child: Text('$chapterNumber'),
        );
      },
    );
  }
}

/// Replaces the old manual "tap to import" gate. The Bible dataset for
/// every language is already bundled inside the app itself
/// (assets/bible/*.json, several MB each, shipped in the APK) — nothing
/// downloads over a network here. "Importing" just means parsing that
/// bundled JSON once and writing it into the local SQLite database,
/// which only needs to happen the first time a given language is
/// opened; after that it's instant on every future launch, same as it
/// always was. There's no reason a person should have to notice or tap
/// anything for a purely local, one-time setup step — this now runs
/// automatically the moment a language without imported data is opened,
/// with just a brief "setting up" spinner rather than a button asking
/// permission to do something that was always going to happen anyway.
class _AutoImportingView extends ConsumerStatefulWidget {
  const _AutoImportingView({super.key, required this.bibleLanguage});

  final String bibleLanguage;

  @override
  ConsumerState<_AutoImportingView> createState() => _AutoImportingViewState();
}

class _AutoImportingViewState extends ConsumerState<_AutoImportingView> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _runImport();
  }

  Future<void> _runImport() async {
    final importer = ref.read(bibleImporterProvider);
    try {
      await importer.importLanguage(widget.bibleLanguage);
      if (!mounted) {
        return;
      }
      ref.invalidate(bibleImportStatusProvider(widget.bibleLanguage));
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(
          () => _error = "Couldn't set up this Bible. Check your storage space "
              'and try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 40, color: AppTheme.textSecondary(context)),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () {
                  setState(() => _error = null);
                  _runImport();
                },
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          EkklesiaCompanion(
            type: EkklesiaCompanionType.bible,
            width: 110,
            isDecorative: true, // the text label below already says it
          ),
          SizedBox(height: 8),
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Setting up your Bible'),
        ],
      ),
    );
  }
}

/// Small floating circular control docked to the side of the reading
/// screen — tap to play/pause, long-press for the full player sheet
/// (scrubber, speed, rewind/fast-forward). Deliberately not a modal or
/// full-width bar: the explicit request was to be able to keep reading
/// the verse text underneath while audio plays, matching the reference
/// screenshots' small side-docked control rather than a blocking player.
class _AudioBibleFloatingButton extends StatelessWidget {
  const _AudioBibleFloatingButton({
    required this.playing,
    required this.downloading,
    required this.downloadProgress,
    required this.onTap,
    required this.onLongPress,
  });

  final bool playing;
  final bool downloading;
  final AudioBibleDownloadProgress? downloadProgress;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    double? progressValue;
    if (downloading &&
        downloadProgress?.total != null &&
        downloadProgress!.total! > 0) {
      progressValue = downloadProgress!.received / downloadProgress!.total!;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: downloading ? null : onTap,
        onLongPress: downloading ? null : onLongPress,
        customBorder: const CircleBorder(),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.accent,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (downloading)
                SizedBox(
                  width: 48,
                  height: 48,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    value: progressValue, // null = indeterminate
                    color: Colors.white,
                    backgroundColor: Colors.white.withValues(alpha: 0.25),
                  ),
                ),
              Icon(
                downloading
                    ? Icons.download_rounded
                    : (playing
                        ? Icons.pause_rounded
                        : Icons.headphones_rounded),
                color: Colors.white,
                size: 26,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full audio-Bible player — reached via long-press on the floating
/// button. Matches the reference screenshot's layout: book title,
/// rewind/play/fast-forward row, a scrubber with elapsed/total time, and
/// a speed control. No separate "download" button here (unlike the
/// reference) — downloading already happens automatically the first
/// time playback starts, so there's nothing extra for the person to
/// trigger manually.
class _AudioBiblePlayerSheet extends StatelessWidget {
  const _AudioBiblePlayerSheet({
    required this.bookName,
    required this.chapterNumber,
    required this.onTogglePlayback,
    required this.playing,
  });

  final String bookName;
  final int chapterNumber;
  final VoidCallback onTogglePlayback;
  final bool playing;

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        decoration: BoxDecoration(
          color: AppTheme.surface(context),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textSecondary(context).withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              bookName,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary(context)),
            ),
            Text(
              'Chapter $chapterNumber',
              style: TextStyle(
                  fontSize: 13, color: AppTheme.textSecondary(context)),
            ),
            const SizedBox(height: 24),
            StreamBuilder<Duration>(
              stream: AudioBibleService.instance.positionStream,
              builder: (context, snapshot) {
                final position = snapshot.data ?? Duration.zero;
                final total =
                    AudioBibleService.instance.duration ?? Duration.zero;
                final totalMs = total.inMilliseconds;
                final sliderValue = totalMs > 0
                    ? (position.inMilliseconds / totalMs).clamp(0.0, 1.0)
                    : 0.0;
                return Column(
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6),
                      ),
                      child: Slider(
                        value: sliderValue,
                        activeColor: AppColors.accent,
                        onChanged: totalMs > 0
                            ? (v) => AudioBibleService.instance.player
                                .seek(total * v)
                            : null,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_formatDuration(position),
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textSecondary(context))),
                          Text(_formatDuration(total),
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textSecondary(context))),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 32,
                  icon: const Icon(Icons.replay_10_rounded),
                  color: AppTheme.textPrimary(context),
                  onPressed: () {
                    final current = AudioBibleService.instance.player.position;
                    AudioBibleService.instance.player
                        .seek(current - const Duration(seconds: 10));
                  },
                ),
                const SizedBox(width: 16),
                StreamBuilder<PlayerState>(
                  stream: AudioBibleService.instance.stateStream,
                  builder: (context, snapshot) {
                    final isPlaying = snapshot.data?.playing ?? playing;
                    return Material(
                      color: AppColors.accent,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: onTogglePlayback,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Icon(
                            isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 16),
                IconButton(
                  iconSize: 32,
                  icon: const Icon(Icons.forward_10_rounded),
                  color: AppTheme.textPrimary(context),
                  onPressed: () {
                    final current = AudioBibleService.instance.player.position;
                    AudioBibleService.instance.player
                        .seek(current + const Duration(seconds: 10));
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            StreamBuilder<double>(
              stream: AudioBibleService.instance.player.speedStream,
              builder: (context, snapshot) {
                final speed = snapshot.data ?? 1.0;
                return TextButton(
                  onPressed: () {
                    // Cycles 1x -> 1.25x -> 1.5x -> 2x -> back to 1x —
                    // simple, no separate menu needed for 4 options.
                    const speeds = [1.0, 1.25, 1.5, 2.0];
                    final currentIndex = speeds.indexOf(speed);
                    final next =
                        speeds[(currentIndex + 1) % speeds.length];
                    AudioBibleService.instance.player.setSpeed(next);
                  },
                  child: Text(
                    '${speed == speed.roundToDouble() ? speed.toInt() : speed}x',
                    style: TextStyle(color: AppTheme.textPrimary(context)),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// On-demand search overlay — see _openSearchSheet's doc comment for
/// why this exists as a separate sheet rather than inline fields.
/// Manages its own local search state (not the parent screen's) since a
/// modal route doesn't rebuild automatically when a parent's setState
/// runs; matches the reference screenshot's layout — a search bar, and
/// a handful of quick "Suggested" shortcuts before anything is typed.
class _BibleSearchSheet extends ConsumerStatefulWidget {
  const _BibleSearchSheet({
    required this.bibleLanguage,
    required this.onJumpToReference,
    required this.onSelectVerse,
  });

  final String bibleLanguage;
  final ValueChanged<String> onJumpToReference;
  final ValueChanged<BibleVerse> onSelectVerse;

  @override
  ConsumerState<_BibleSearchSheet> createState() => _BibleSearchSheetState();
}

class _BibleSearchSheetState extends ConsumerState<_BibleSearchSheet> {
  final _controller = TextEditingController();
  List<BibleVerse> _results = [];
  bool _searching = false;

  // Matches the reference screenshot's exact suggestions — well-known,
  // frequently-looked-up passages someone new to the app is likely to
  // want, not a personalized or dynamically-computed list.
  static const _suggestions = [
    'Psalm 1',
    'Proverbs',
    'Genesis',
    'Psalm 23',
    'Isaiah',
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final repo = ref.read(bibleRepositoryProvider);
      final results = await repo.search(widget.bibleLanguage, query);
      if (mounted) setState(() => _results = results);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        // Lifts the sheet above the on-screen keyboard so the search
        // field and results stay visible while typing.
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          autofocus: true,
                          decoration: InputDecoration(
                            hintText: l10n.bibleSearchHint,
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: _controller.text.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.close_rounded),
                                    onPressed: () {
                                      _controller.clear();
                                      setState(() => _results = []);
                                    },
                                  ),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24)),
                            isDense: true,
                          ),
                          onChanged: _runSearch,
                          onSubmitted: widget.onJumpToReference,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _controller.text.trim().isEmpty
                        ? ListView(
                            controller: scrollController,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 8),
                                child: Text('Suggested',
                                    style: TextStyle(
                                        fontSize: 13,
                                        color:
                                            AppTheme.textSecondary(context))),
                              ),
                              for (final s in _suggestions)
                                ListTile(
                                  title: Text(s,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  trailing: const Icon(
                                      Icons.chevron_right_rounded),
                                  onTap: () => widget.onJumpToReference(s),
                                ),
                            ],
                          )
                        : _searching
                            ? const Center(
                                child: CircularProgressIndicator())
                            : _results.isEmpty
                                ? Center(child: Text(l10n.bibleNoMatches))
                                : ListView.builder(
                                    controller: scrollController,
                                    itemCount: _results.length,
                                    itemBuilder: (context, i) {
                                      final v = _results[i];
                                      return ListTile(
                                        title: Text(
                                            '${v.bookCode} ${v.chapter}:${v.number}'),
                                        subtitle: Text(v.content ?? '',
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis),
                                        onTap: () =>
                                            widget.onSelectVerse(v),
                                      );
                                    },
                                  ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
