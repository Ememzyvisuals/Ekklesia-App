import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show PlayerState;

import '../../../core/config/app_theme.dart';
import '../../../core/config/app_config.dart';
import '../../../core/services/tts_service.dart';
import '../../../core/services/local_tts_engine.dart'
    show TtsModelNotReadyException;
import '../../../core/services/system_tts_engine.dart'
    show SystemTtsTimeoutException;
import '../../../core/services/audio_service.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../bookmarks/presentation/bookmark_button.dart';
import '../../bookmarks/domain/bookmark_item.dart';
import '../../../core/database/app_database.dart';
import '../data/bible_audio_cache.dart';
import '../data/bible_providers.dart';
import '../data/bible_repository.dart';
import '../data/bible_tts_queue.dart';
import 'voice_download_sheet.dart';
import '../../../core/widgets/ekklesia_companion.dart';
import '../../../core/services/app_settings_service.dart';

enum _View { books, chapters, verses }

/// Offline Bible reader — reads from the local Isar database populated by
/// [BibleImporter], not from any network API.
///
/// Scope note (honest, as of this pass): book/chapter navigation, verse
/// list, reference jump, offline substring search, bookmarking, verse
/// highlights (colored), verse notes, "Continue Reading," reading streak,
/// localization (en/yo/ha/ig/pcm), and chapter listen (via the existing
/// TtsService/AudioService pipeline) are implemented. Generated chapter
/// audio is cached to local disk (BibleAudioCache) keyed by chapter text,
/// so replaying the same chapter plays instantly from disk instead of
/// re-hitting the TTS Space — but generation itself is still "whole
/// chapter up front," not the spec's chunked prefetch-while-playing
/// streaming queue (BibleTTSQueue etc.) — see BIBLE_IMPORT_NOTES.md.
/// NOT yet implemented: dedicated background workers (BibleSyncWorker
/// etc. — Bible audio cache reconciliation is folded into the existing
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
  final _searchController = TextEditingController();
  List<BibleVerse> _searchResults = [];
  bool _searching = false;
  bool _loadingVerses = false;
  bool _loadingAudio = false;
  String? _error;
  // Holds the real, unfiltered exception text behind a friendly TTS
  // error — set alongside `_error` only for the generic/unexpected
  // failure paths below. `_error` stays the calm, friendly message
  // shown by default; this is only surfaced if the person deliberately
  // taps "Details," so it doesn't clutter the normal UI, but a real
  // error is only one tap away instead of permanently invisible.
  String? _errorDetail;
  StreamSubscription<(int, int)?>? _queueProgressSub;
  String? _queueProgressLabel;
  Map<int, Highlight> _highlights = {};

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

  Future<void> _runSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final repo = ref.read(bibleRepositoryProvider);
      final results = await repo.search(_bibleLanguage, query);
      setState(() => _searchResults = results);
    } finally {
      setState(() => _searching = false);
    }
  }

  Future<void> _listenToChapter() async {
    if (_verses.isEmpty || _selectedBook == null || _selectedChapter == null) {
      return;
    }
    final bibleLanguage = ref.read(bibleLanguageProvider);
    final book = _selectedBook!;
    final chapterNumber = _selectedChapter!;
    final ekklesiaLanguage = _ekklesiaLanguageFor(bibleLanguage);
    final fullText = _verses
        .map((v) => v.content ?? '')
        .where((t) => t.isNotEmpty)
        .join(' ');
    final contentHash = BibleAudioCache.hashFor(fullText);
    final cache = ref.read(bibleAudioCacheProvider);

    setState(() {
      _loadingAudio = true;
      _queueProgressLabel = null;
      _error = null;
      _errorDetail = null;
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
      // Already generated and downloaded for this exact chapter text? Play
      // straight from disk — no TTS Space call, no wait, no quota spent.
      final cached =
          await cache.get(bibleLanguage, book.code, chapterNumber, contentHash);
      if (cached != null) {
        final items = Stream.fromIterable(
          cached.chunkPaths.map((p) => (
                Uri.file(p).toString(),
                cache.sourceFor(cached.audioSourceName)
              )),
        );
        await AudioService.instance.playQueue(items);
        return;
      }

      // Not cached (or the chapter's text changed since it was last
      // cached) — generate with look-ahead prefetch (BibleTTSQueue) so
      // chunk N+1 generates while chunk N plays instead of strictly one
      // at a time, while also collecting every chunk so it can be saved
      // to disk for next time once playback finishes.
      final generated = <TtsResult>[];
      Stream<(String, AudioSource)> instrumented() async* {
        final chunks =
            BibleTTSQueue().stream(text: fullText, language: ekklesiaLanguage);
        await for (final result in chunks) {
          generated.add(result);
          yield (result.audioUrl, result.source);
        }
      }

      await AudioService.instance.playQueue(instrumented());

      if (generated.isNotEmpty) {
        // Fire-and-forget: downloading to disk shouldn't hold up the UI
        // now that listening has already finished. Failure here just
        // means next time re-generates too — not a playback error.
        // .then(...).catchError(...) rather than a bare .catchError on
        // save()'s own Future — save() resolves to a
        // BibleAudioCacheEntity, so its catchError handler would need to
        // return one too; converting to Future<void> first with .then
        // sidesteps that entirely and matches what this call site
        // actually means ("run this, ignore the result either way").
        unawaited(
          cache
              .save(
                language: bibleLanguage,
                bookCode: book.code,
                chapter: chapterNumber,
                contentHash: contentHash,
                chunks: generated,
              )
              .then((_) {})
              .catchError((_) {}),
        );
      }
    } on TtsModelNotReadyException catch (e) {
      // Not an error — the voice just isn't downloaded yet. Route to the
      // download picker instead of showing a generic error message.
      setState(() {
        _error = null;
        _errorDetail = null;
      });
      _promptModelDownload(e.mmsCode);
    } on TtsLanguageUnavailableException {
      setState(() {
        _error = 'No offline voice is available for this language yet.';
        _errorDetail = null;
      });
    } on SystemTtsTimeoutException {
      // See system_tts_engine.dart's doc comment: confirmed on a real
      // device that hitting Listen on the English Bible could hang
      // forever with the old unguarded flutter_tts call. This is that
      // same failure, now bounded and visible instead of an infinite
      // spinner.
      setState(() {
        _error = "Your device's voice engine did not respond. Try again, or "
            'check that a text-to-speech engine is installed and enabled '
            "in your phone's settings.";
        _errorDetail = null;
      });
    } on TtsGenerationException catch (e) {
      setState(() {
        _error = _friendlyTtsError(e);
        // e.message already carries the real underlying exception text
        // (tts_service.dart builds it as 'Could not generate audio: $e')
        // — previously discarded entirely in favor of the generic
        // message above, which made every real failure look identical
        // and impossible to actually diagnose without device logs.
        _errorDetail = e.message;
      });
    } catch (e) {
      setState(() {
        _error = 'Something went wrong generating audio. Try again.';
        _errorDetail = e.toString();
      });
    } finally {
      setState(() {
        _loadingAudio = false;
        _queueProgressLabel = null;
      });
    }
  }

  /// PROJECT_MIGRATION_AUDIT.md Phase 5: TTS is fully on-device now (or,
  /// for Igbo, unavailable — see TtsLanguageUnavailableException). This
  /// used to translate GradioErrorType (cloud service state: waking up,
  /// rate-limited, etc.) — none of that applies anymore. What's left to
  /// translate is genuine local synthesis failures.
  String _friendlyTtsError(TtsGenerationException e) {
    return 'Could not generate audio right now. Please try again.';
  }

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

  Future<void> _promptModelDownload(String mmsCode) async {
    final download = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => VoiceDownloadSheet(mmsCode: mmsCode),
    );
    if (download == true && mounted) {
      // Retry the same chapter's playback now that the model should be
      // ready — the user just watched it finish downloading in the sheet.
      _listenToChapter();
    }
  }

  EkklesiaLanguage _ekklesiaLanguageFor(String bibleCode) {
    switch (bibleCode) {
      case 'yo':
        return EkklesiaLanguage.yoruba;
      case 'ha':
        return EkklesiaLanguage.hausa;
      case 'ig':
        return EkklesiaLanguage.igbo;
      case 'pcm':
        return EkklesiaLanguage.pidgin;
      case 'en':
      default:
        return EkklesiaLanguage.english;
    }
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
    _queueProgressSub?.cancel();
    _blinkTimer?.cancel();
    _referenceController.dispose();
    _searchController.dispose();
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
    final l10n = AppLocalizations.of(context);
    return Column(
      key: key,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _referenceController,
                  decoration: InputDecoration(
                    hintText: l10n.bibleReferenceLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _jumpToReference(),
                ),
              ),
              IconButton(
                  icon: const Icon(Icons.search_rounded),
                  onPressed: _jumpToReference),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: l10n.bibleSearchHint,
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: _searching
                    ? const Padding(
                        key: ValueKey('spinner'),
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('empty')),
              ),
            ),
            onChanged: _runSearch,
          ),
        ),
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
        if (_searchController.text.isNotEmpty)
          Expanded(child: _buildSearchResults(bibleLanguage))
        else
          Expanded(child: _buildNavigation(bibleLanguage)),
      ],
    );
  }

  Widget _buildSearchResults(String bibleLanguage) {
    final l10n = AppLocalizations.of(context);
    if (_searchResults.isEmpty) {
      return Center(child: Text(l10n.bibleNoMatches));
    }
    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (context, i) {
        final v = _searchResults[i];
        return ListTile(
          title: Text('${v.bookCode} ${v.chapter}:${v.number}'),
          subtitle: Text(v.content ?? '',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          onTap: () async {
            final repo = ref.read(bibleRepositoryProvider);
            final books = await repo.getBooks(bibleLanguage);
            final book = books.firstWhere((b) => b.code == v.bookCode);
            _searchController.clear();
            await _openChapter(book, v.chapter);
          },
        );
      },
    );
  }

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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Compact utility row — search/settings-style icon buttons
        // instead of the old header eating a full text-label row; the
        // book/chapter identity now lives in the big centered header
        // below, matching how a real Bible app (see the reference
        // screenshots) keeps chrome quiet and lets the chapter number
        // itself be the visual anchor.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (_ekklesiaLanguageFor(ref.watch(bibleLanguageProvider)) !=
                  EkklesiaLanguage.igbo)
                IconButton(
                  onPressed: _loadingAudio ? null : _listenToChapter,
                  tooltip: l10n.bibleListen,
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: _loadingAudio
                        ? const SizedBox(
                            key: ValueKey('spinner'),
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.headphones_rounded,
                            key: ValueKey('icon')),
                  ),
                ),
            ],
          ),
        ),
        if (_loadingAudio && _queueProgressLabel != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(_queueProgressLabel!,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary(context))),
          ),
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
        // AI-narration disclosure — spec's explicit requirement that
        // users always know this is AI-generated audio, not a human
        // reading, and that it can make mistakes (mispronunciation,
        // wrong emphasis). Shown only while there's actually audio
        // loading or playing, not permanently, so it doesn't clutter the
        // reading screen the rest of the time. StreamBuilder rather than
        // a plain getter check — this widget isn't otherwise rebuilt
        // when playback starts/stops on its own.
        StreamBuilder<PlayerState>(
          stream: AudioService.instance.playerStateStream,
          builder: (context, snapshot) {
            final playing = snapshot.data?.playing ?? false;
            if (!_loadingAudio && !playing) {
              return const SizedBox.shrink();
            }
            return Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.smart_toy_outlined, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'AI-generated voice. May mispronounce words or names.',
                      style: TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary(context)),
                    ),
                  ),
                ],
              ),
            );
          },
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
                            onPressed: () => _openChapter(book, chapter + 1),
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
              final isBlinking = _blinkVerseNumber == v.number && _blinkVisible;
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
