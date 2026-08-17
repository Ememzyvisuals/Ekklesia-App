import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Ekklesia's visual identity per the master build spec: Forest Green,
/// Stone, and Warm Gold — calm, peaceful, premium. Not the orange/green
/// WazobiaVoice-derived palette this file previously carried; that was a
/// leftover from a different brand and has been fully replaced.
class AppColors {
  AppColors._();

  static const Color primary = Color(0xFF1F5E3B); // Forest Green
  static const Color secondary = Color(0xFFF5F4EF); // Stone
  static const Color accent = Color(0xFFC8A24D); // Warm Gold

  static const Color backgroundLight = Color(0xFFFAFAF7);
  static const Color backgroundDark = Color(0xFF121212);
  static const Color cardLight = Color(0xFFFFFFFF);
  static const Color cardDark = Color(0xFF1C1C1C);

  static const Color success = Color(0xFF2E7D32);
  static const Color warning = Color(0xFFEDB000);
  static const Color error = Color(0xFFC62828);
  static const Color info = Color(0xFF1976D2);

  // Text colors aren't specified as hex values in the master spec, only
  // "consistent, theme-aware" — these are chosen for AA contrast against
  // backgroundLight/backgroundDark and cardLight/cardDark above.
  static const Color textPrimaryLight = Color(0xFF1A1F1C);
  static const Color textSecondaryLight = Color(0xFF5B6560);
  static const Color textPrimaryDark = Color(0xFFF2F3F1);
  static const Color textSecondaryDark = Color(0xFFA9B3AE);

  // Legacy aliases so existing screens referencing AppColors.surface /
  // .background / .textPrimary (light-mode-only, non-context-aware) keep
  // compiling while they're migrated to the context-aware AppTheme helpers
  // below. New code should use AppTheme.surface(context) etc., not these.
  static const Color background = backgroundLight;
  static const Color surface = cardLight;
  static const Color textPrimary = textPrimaryLight;
  static const Color textSecondary = textSecondaryLight;
}

/// The spec's 12-step Outfit typography scale, as real named TextStyles —
/// not ad-hoc GoogleFonts.outfit() calls scattered per-widget. Weights only
/// go 300-700 per the spec; sentence case is a content convention (enforced
/// by review, not by this class) rather than a text-transform.
///
/// Uses the bundled `assets/fonts/Outfit-Variable.ttf` directly via a
/// plain TextStyle(fontFamily: 'Outfit') rather than GoogleFonts.outfit(),
/// which was the actual cause of every screenshot from a real device
/// showing the system font instead of Outfit: GoogleFonts fetches the
/// font file from Google's CDN over the network on first use and only
/// falls back to the system font silently if that fetch fails — for an
/// offline-first app, "the very first launch has no internet yet" isn't
/// an edge case, it's close to the expected case. Bundling the real font
/// file (pulled from google/fonts' own GitHub repo, same font, same
/// license) means Outfit renders correctly from the first frame,
/// online or not.
class AppTypography {
  AppTypography._();

  static TextStyle _style(double size, FontWeight weight, {Color? color}) =>
      TextStyle(
        fontFamily: 'Outfit',
        fontSize: size,
        fontWeight: weight,
        color: color,
      );

  static TextStyle displayLarge({Color? color}) =>
      _style(56, FontWeight.w700, color: color);
  static TextStyle displayMedium({Color? color}) =>
      _style(48, FontWeight.w700, color: color);
  static TextStyle headlineLarge({Color? color}) =>
      _style(36, FontWeight.w600, color: color);
  static TextStyle headlineMedium({Color? color}) =>
      _style(32, FontWeight.w600, color: color);
  static TextStyle titleLarge({Color? color}) =>
      _style(24, FontWeight.w600, color: color);
  static TextStyle titleMedium({Color? color}) =>
      _style(20, FontWeight.w500, color: color);
  static TextStyle titleSmall({Color? color}) =>
      _style(18, FontWeight.w500, color: color);
  static TextStyle bodyLarge({Color? color}) =>
      _style(16, FontWeight.w400, color: color);
  static TextStyle bodyMedium({Color? color}) =>
      _style(15, FontWeight.w400, color: color);
  static TextStyle bodySmall({Color? color}) =>
      _style(14, FontWeight.w400, color: color);
  static TextStyle caption({Color? color}) =>
      _style(12, FontWeight.w400, color: color);
  static TextStyle button({Color? color}) =>
      _style(16, FontWeight.w600, color: color);
}

class AppTheme {
  AppTheme._();

  /// iOS-style push/pop slide on every route, every platform — this is
  /// the single change that makes screen-to-screen navigation feel
  /// premium/iOS-like app-wide, rather than something to hand-roll per
  /// screen. Deliberately just the platform's own standard transition
  /// (a subtle horizontal slide + fade), not a custom animation — matches
  /// the explicit "smooth, not over-animated" direction this app's
  /// screens (e.g. bible_screen.dart's AnimatedSwitcher) already follow.
  static const _iosStylePageTransitions = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
      TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
    },
  );

  static TextTheme _textTheme(Brightness brightness) {
    final primary = brightness == Brightness.dark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimaryLight;
    final secondary = brightness == Brightness.dark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondaryLight;

    return TextTheme(
      displayLarge: AppTypography.displayLarge(color: primary),
      displayMedium: AppTypography.displayMedium(color: primary),
      headlineLarge: AppTypography.headlineLarge(color: primary),
      headlineMedium: AppTypography.headlineMedium(color: primary),
      titleLarge: AppTypography.titleLarge(color: primary),
      titleMedium: AppTypography.titleMedium(color: primary),
      titleSmall: AppTypography.titleSmall(color: primary),
      bodyLarge: AppTypography.bodyLarge(color: primary),
      bodyMedium: AppTypography.bodyMedium(color: secondary),
      bodySmall: AppTypography.bodySmall(color: secondary),
      labelSmall: AppTypography.caption(color: secondary),
      labelLarge: AppTypography.button(color: primary),
    );
  }

  static ThemeData get light {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.backgroundLight,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppColors.primary,
        secondary: AppColors.secondary,
        tertiary: AppColors.accent,
        surface: AppColors.cardLight,
        error: AppColors.error,
      ),
    );
    return base.copyWith(
      textTheme: _textTheme(Brightness.light),
      pageTransitionsTheme: _iosStylePageTransitions,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.backgroundLight,
        foregroundColor: AppColors.textPrimaryLight,
        elevation: 0,
        centerTitle: true,
        titleTextStyle:
            AppTypography.titleMedium(color: AppColors.textPrimaryLight),
      ),
      cardTheme: CardThemeData(
        color: AppColors.cardLight,
        elevation: 0,
        shadowColor: Colors.black.withValues(alpha: 0.06),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          textStyle: AppTypography.button(),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }

  static ThemeData get dark {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.backgroundDark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.dark,
      ).copyWith(
        primary: AppColors
            .accent, // Gold reads better as the dark-mode accent than deep green
        secondary: AppColors.primary,
        tertiary: AppColors.accent,
        surface: AppColors.cardDark,
        error: AppColors.error,
      ),
    );
    return base.copyWith(
      textTheme: _textTheme(Brightness.dark),
      pageTransitionsTheme: _iosStylePageTransitions,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.backgroundDark,
        foregroundColor: AppColors.textPrimaryDark,
        elevation: 0,
        centerTitle: true,
        titleTextStyle:
            AppTypography.titleMedium(color: AppColors.textPrimaryDark),
      ),
      cardTheme: CardThemeData(
        color: AppColors.cardDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
              color: Colors.white.withValues(alpha: 0.06), width: 0.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: AppColors.textPrimaryLight,
          textStyle: AppTypography.button(),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }

  /// Theme-aware surface/text colors for widgets that need to adapt
  /// without rebuilding via Theme.of(context) everywhere.
  static Color surface(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? AppColors.cardDark
          : AppColors.cardLight;

  static Color textPrimary(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? AppColors.textPrimaryDark
          : AppColors.textPrimaryLight;

  static Color textSecondary(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? AppColors.textSecondaryDark
          : AppColors.textSecondaryLight;
}
