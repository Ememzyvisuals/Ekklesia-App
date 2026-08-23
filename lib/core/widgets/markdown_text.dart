import 'package:flutter/material.dart';

import '../config/app_theme.dart';

/// Renders Groq's Markdown-formatted replies (AI Assistant chat, Impact
/// Academy summaries) as real, readable widgets instead of showing raw
/// `**`/`#`/`|` characters straight in the UI.
///
/// Deliberately a small hand-written parser rather than pulling in
/// `flutter_markdown` (or similar) — this project's whole workflow (see
/// EKKLESIA_HANDOFF.md) relies on static reading/verification because
/// there's no local Flutter SDK to compile against, and a hand-written
/// widget whose entire behavior is visible in this one file is far
/// easier to verify that way than trusting an unfamiliar third-party
/// package's exact API surface and rendering quirks sight-unseen. For
/// the same reason, this deliberately avoids Dart 3's sealed-class
/// pattern-matching switches (harder to eyeball-verify without a
/// compiler) in favor of plain `is` checks. This covers what Groq
/// actually produces in this app (headers, bold, italic, inline code,
/// bullet/numbered lists, pipe tables) rather than full CommonMark —
/// that's a deliberate, honest scope limit, not an oversight.
class MarkdownText extends StatelessWidget {
  const MarkdownText(
    this.data, {
    super.key,
    this.baseStyle,
    this.bodyFontSize,
  });

  final String data;

  /// Base text style for body paragraphs/list items — headers and inline
  /// code are derived from this. Falls back to the theme's default body
  /// style (with AppTheme.textPrimary's color) if not given.
  final TextStyle? baseStyle;

  /// Overrides the font size of [baseStyle] specifically — used by
  /// callers that apply the app's font-size preference without needing
  /// to reconstruct a whole TextStyle.
  final double? bodyFontSize;

  @override
  Widget build(BuildContext context) {
    final resolvedBase = (baseStyle ??
            TextStyle(color: AppTheme.textPrimary(context), fontSize: 15))
        .copyWith(fontSize: bodyFontSize ?? baseStyle?.fontSize ?? 15);

    final blocks = _parseBlocks(data);
    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      children.add(_buildBlock(context, blocks[i], resolvedBase));
      if (i != blocks.length - 1) {
        children.add(const SizedBox(height: 8));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _buildBlock(BuildContext context, _Block block, TextStyle base) {
    if (block is _HeaderBlock) {
      const sizes = {1: 22.0, 2: 19.0, 3: 17.0};
      return Text.rich(
        _inlineSpans(
          block.text,
          base.copyWith(
            fontSize: sizes[block.level] ?? 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }

    if (block is _ParagraphBlock) {
      return Text.rich(_inlineSpans(block.text, base));
    }

    if (block is _BulletListBlock) {
      final rows = <Widget>[];
      for (final item in block.items) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('\u2022  ', style: base),
                Expanded(child: Text.rich(_inlineSpans(item, base))),
              ],
            ),
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: rows,
      );
    }

    if (block is _NumberedListBlock) {
      final rows = <Widget>[];
      for (var i = 0; i < block.items.length; i++) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${i + 1}.  ', style: base),
                Expanded(child: Text.rich(_inlineSpans(block.items[i], base))),
              ],
            ),
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: rows,
      );
    }

    if (block is _TableBlock) {
      final borderColor =
          AppTheme.textSecondary(context).withValues(alpha: 0.3);
      final headerCells = <Widget>[];
      for (final cell in block.headerRow) {
        headerCells.add(
          Padding(
            padding: const EdgeInsets.all(6),
            child: Text.rich(
              _inlineSpans(cell, base.copyWith(fontWeight: FontWeight.bold)),
            ),
          ),
        );
      }
      final dataRows = <TableRow>[];
      for (final row in block.rows) {
        final cells = <Widget>[];
        for (final cell in row) {
          cells.add(
            Padding(
              padding: const EdgeInsets.all(6),
              child: Text.rich(_inlineSpans(cell, base)),
            ),
          );
        }
        dataRows.add(TableRow(children: cells));
      }
      return Table(
        border: TableBorder.all(color: borderColor),
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        children: [
          TableRow(
            decoration: BoxDecoration(
              color: AppTheme.textSecondary(context).withValues(alpha: 0.08),
            ),
            children: headerCells,
          ),
          ...dataRows,
        ],
      );
    }

    // Defensive fallback — every _Block subtype above is handled, this
    // only fires if a new subtype is added without updating this method.
    return const SizedBox.shrink();
  }

  /// Parses `**bold**`, `*italic*`/`_italic_`, and `` `code` `` inline
  /// spans within a single block of text. Not recursive (no
  /// bold-inside-italic nesting) — Groq's actual output never needed
  /// that, and real CommonMark nesting rules are a lot more machinery
  /// than this app's display needs.
  TextSpan _inlineSpans(String text, TextStyle base) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(
      r'\*\*(.+?)\*\*|__(.+?)__|\*(.+?)\*|_(.+?)_|`(.+?)`',
    );
    var last = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start)));
      }
      if (match.group(1) != null || match.group(2) != null) {
        spans.add(TextSpan(
          text: match.group(1) ?? match.group(2),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ));
      } else if (match.group(3) != null || match.group(4) != null) {
        spans.add(TextSpan(
          text: match.group(3) ?? match.group(4),
          style: const TextStyle(fontStyle: FontStyle.italic),
        ));
      } else if (match.group(5) != null) {
        spans.add(TextSpan(
          text: match.group(5),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ));
      }
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }
    return TextSpan(style: base, children: spans);
  }

  List<_Block> _parseBlocks(String input) {
    final lines = input.replaceAll('\r\n', '\n').split('\n');
    final blocks = <_Block>[];
    var i = 0;

    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        i++;
        continue;
      }

      // Pipe table: a header row, a separator row of only -, :, |, and
      // whitespace, then zero or more data rows.
      if (_looksLikeTableRow(trimmed) &&
          i + 1 < lines.length &&
          _isTableSeparator(lines[i + 1].trim())) {
        final headerRow = _splitTableRow(trimmed);
        final dataRows = <List<String>>[];
        var j = i + 2;
        while (j < lines.length && _looksLikeTableRow(lines[j].trim())) {
          dataRows.add(_splitTableRow(lines[j].trim()));
          j++;
        }
        blocks.add(_TableBlock(headerRow: headerRow, rows: dataRows));
        i = j;
        continue;
      }

      // Header: one to six '#' then a space.
      final headerMatch = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
      if (headerMatch != null) {
        blocks.add(_HeaderBlock(
          level: headerMatch.group(1)!.length,
          text: headerMatch.group(2)!.trim(),
        ));
        i++;
        continue;
      }

      // Bullet list: consecutive lines starting with -, *, or a bullet.
      if (RegExp(r'^[-*\u2022]\s+').hasMatch(trimmed)) {
        final items = <String>[];
        var j = i;
        while (j < lines.length &&
            RegExp(r'^[-*\u2022]\s+').hasMatch(lines[j].trim())) {
          items
              .add(lines[j].trim().replaceFirst(RegExp(r'^[-*\u2022]\s+'), ''));
          j++;
        }
        blocks.add(_BulletListBlock(items: items));
        i = j;
        continue;
      }

      // Numbered list: consecutive lines starting with "1. ", "2. ", etc.
      if (RegExp(r'^\d+\.\s+').hasMatch(trimmed)) {
        final items = <String>[];
        var j = i;
        while (j < lines.length &&
            RegExp(r'^\d+\.\s+').hasMatch(lines[j].trim())) {
          items.add(lines[j].trim().replaceFirst(RegExp(r'^\d+\.\s+'), ''));
          j++;
        }
        blocks.add(_NumberedListBlock(items: items));
        i = j;
        continue;
      }

      // Horizontal rule — skip entirely, nothing useful to render.
      if (RegExp(r'^-{3,}$').hasMatch(trimmed) ||
          RegExp(r'^\*{3,}$').hasMatch(trimmed)) {
        i++;
        continue;
      }

      // Plain paragraph: absorb consecutive non-blank, non-special lines
      // into one paragraph so wrapped sentences don't each become their
      // own block.
      final paraLines = <String>[trimmed];
      var j = i + 1;
      while (j < lines.length &&
          lines[j].trim().isNotEmpty &&
          !RegExp(r'^[-*\u2022]\s+').hasMatch(lines[j].trim()) &&
          !RegExp(r'^\d+\.\s+').hasMatch(lines[j].trim()) &&
          !RegExp(r'^#{1,6}\s+').hasMatch(lines[j].trim()) &&
          !_looksLikeTableRow(lines[j].trim())) {
        paraLines.add(lines[j].trim());
        j++;
      }
      blocks.add(_ParagraphBlock(text: paraLines.join(' ')));
      i = j;
    }

    return blocks;
  }

  bool _looksLikeTableRow(String line) =>
      line.startsWith('|') && line.endsWith('|') && line.length > 1;

  bool _isTableSeparator(String line) =>
      _looksLikeTableRow(line) && RegExp(r'^[|\s:-]+$').hasMatch(line);

  List<String> _splitTableRow(String line) {
    final inner = line.substring(1, line.length - 1);
    return inner.split('|').map((c) => c.trim()).toList();
  }
}

abstract class _Block {}

class _HeaderBlock extends _Block {
  _HeaderBlock({required this.level, required this.text});
  final int level;
  final String text;
}

class _ParagraphBlock extends _Block {
  _ParagraphBlock({required this.text});
  final String text;
}

class _BulletListBlock extends _Block {
  _BulletListBlock({required this.items});
  final List<String> items;
}

class _NumberedListBlock extends _Block {
  _NumberedListBlock({required this.items});
  final List<String> items;
}

class _TableBlock extends _Block {
  _TableBlock({required this.headerRow, required this.rows});
  final List<String> headerRow;
  final List<List<String>> rows;
}

/// Strips Markdown syntax down to plain, readable text — for contexts
/// that need a single-line or `maxLines`-truncated preview (Home
/// screen's Today's Verse/Prayer cards) where the full block-widget
/// renderer above can't apply (a Column of blocks has no single
/// `maxLines`/ellipsis to truncate against). Not a full parser — just
/// removes the syntax characters so nothing shows raw asterisks/hashes,
/// while keeping the underlying words intact. Uses `replaceAllMapped`
/// throughout rather than `replaceAll` with a `$1`-style replacement
/// string — Dart's `String.replaceAll` does not support backreferences
/// in its replacement argument the way some other languages do; only
/// `replaceAllMapped`'s callback form can pull out a captured group.
String stripMarkdown(String input) {
  var out = input;

  // Pipe table separator rows (e.g. "|---|---|") — drop entirely.
  out = out.replaceAll(RegExp(r'^\|[\s:|-]+\|$', multiLine: true), ' ');
  // Remaining pipe table rows — join cells with a dash instead of pipes.
  out = out.replaceAllMapped(
    RegExp(r'^\|(.+)\|$', multiLine: true),
    (m) => m.group(1)!.split('|').map((c) => c.trim()).join(' - '),
  );
  out = out.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
  out = out.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m.group(1) ?? '');
  out = out.replaceAllMapped(RegExp(r'__(.+?)__'), (m) => m.group(1) ?? '');
  out = out.replaceAllMapped(
      RegExp(r'(?<![\w*])\*(?!\*)(.+?)\*(?!\*)'), (m) => m.group(1) ?? '');
  out = out.replaceAllMapped(
      RegExp(r'(?<!_)_(?!_)(.+?)_(?!_)'), (m) => m.group(1) ?? '');
  out = out.replaceAllMapped(RegExp(r'`(.+?)`'), (m) => m.group(1) ?? '');
  out = out.replaceAll(RegExp(r'^[-*\u2022]\s+', multiLine: true), '');
  out = out.replaceAll(RegExp(r'^\d+\.\s+', multiLine: true), '');
  out = out.replaceAll(RegExp(r'^-{3,}$', multiLine: true), '');
  return out.replaceAll(RegExp(r'\n{2,}'), '\n').trim();
}
