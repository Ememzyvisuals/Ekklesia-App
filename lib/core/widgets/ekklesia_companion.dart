import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';

/// The four semantic companion roles, mapped to the four supplied
/// character illustrations by their actual appearance/pose — not by
/// arbitrary file order:
///   - [welcome]: standing, waving, holding a Bible — greeting posture.
///   - [bible]: seated, reading an open Bible — reading/study posture.
///   - [prayer]: kneeling, hands clasped, eyes closed — prayer posture.
///     Also the general "something is empty, or something went wrong"
///     companion elsewhere in the app (explicitly requested) — a
///     peaceful, waiting pose reads naturally for both prayer and
///     empty/error states.
///   - [ai]: seated with a laptop, prompt bubbles, a lightbulb — the AI
///     assistant's own posture.
enum EkklesiaCompanionType { welcome, bible, prayer, ai }

/// A single reusable widget for every character illustration in the
/// app, instead of hardcoding `Image.asset(...)` per screen. Centralizes
/// the type-to-asset mapping, sizing defaults, and accessibility
/// semantics in one place — change an asset path or a default size once
/// here rather than hunting down every call site.
///
/// Deliberately small by default (see [_defaultSize]) — these are meant
/// to add warmth to an empty/welcome/loading moment, never to compete
/// with the actual content (scripture text, chat messages, the prayer
/// itself) for visual attention. Callers needing a different size still
/// go through [width]/[height] rather than reaching for the raw asset
/// directly.
class EkklesiaCompanion extends StatelessWidget {
  const EkklesiaCompanion({
    super.key,
    required this.type,
    this.width,
    this.height,
    this.alignment = Alignment.center,
    this.fit = BoxFit.contain,
    this.animate = false,
    this.isDecorative = false,
  });

  final EkklesiaCompanionType type;
  final double? width;
  final double? height;
  final Alignment alignment;
  final BoxFit fit;

  /// A subtle, slow float — deliberately not a bounce/spin/anything
  /// that reads as playful or childish (spec: "No excessive animations.
  /// No childish UI."). Off by default; opt in per call site.
  final bool animate;

  /// True when the illustration is purely decorative in this specific
  /// context (a caption right below it already conveys the same
  /// meaning to a screen reader) — excludes it from the accessibility
  /// tree entirely rather than giving a screen-reader user a redundant
  /// or confusing announcement.
  final bool isDecorative;

  static const double _defaultSize = 120;

  String get _assetPath {
    switch (type) {
      case EkklesiaCompanionType.welcome:
        return 'assets/characters/companion_01.png';
      case EkklesiaCompanionType.bible:
        return 'assets/characters/companion_02.png';
      case EkklesiaCompanionType.prayer:
        return 'assets/characters/companion_03.png';
      case EkklesiaCompanionType.ai:
        return 'assets/characters/companion_04.png';
    }
  }

  String _semanticLabel(AppLocalizations l10n) {
    switch (type) {
      case EkklesiaCompanionType.welcome:
        return l10n.companionWelcomeSemantic;
      case EkklesiaCompanionType.bible:
        return l10n.companionBibleSemantic;
      case EkklesiaCompanionType.prayer:
        return l10n.companionPrayerSemantic;
      case EkklesiaCompanionType.ai:
        return l10n.companionAiSemantic;
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      _assetPath,
      width: width ?? _defaultSize,
      height: height,
      alignment: alignment,
      fit: fit,
      // Decorative at the Image-widget level regardless of
      // [isDecorative] — semantics are applied once, correctly, via the
      // Semantics wrapper below instead of letting Image.asset's own
      // (more limited) semanticLabel duplicate or conflict with it.
      excludeFromSemantics: true,
    );

    final content = animate ? _FloatingCompanion(child: image) : image;

    return Semantics(
      label: isDecorative ? null : _semanticLabel(AppLocalizations.of(context)),
      image: !isDecorative,
      excludeSemantics: isDecorative,
      child: content,
    );
  }
}

class _FloatingCompanion extends StatefulWidget {
  const _FloatingCompanion({required this.child});
  final Widget child;

  @override
  State<_FloatingCompanion> createState() => _FloatingCompanionState();
}

class _FloatingCompanionState extends State<_FloatingCompanion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _offset;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
    _offset = Tween<double>(begin: -4, end: 4).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _offset,
      builder: (context, child) =>
          Transform.translate(offset: Offset(0, _offset.value), child: child),
      child: widget.child,
    );
  }
}
