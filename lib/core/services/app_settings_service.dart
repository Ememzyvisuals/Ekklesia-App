import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted app preferences: theme mode and preferred language. Backed
/// by SharedPreferences, fully local. The old doc comment here claimed
/// this synced to Firestore's `user_settings` collection via a
/// `SettingsSyncService` — that class never existed anywhere in the
/// codebase (confirmed while scanning for stale claims,
/// PROJECT_MIGRATION_AUDIT.md Phase 4 cleanup); this was always local
/// only. Cross-device sync isn't applicable anymore anyway — there's no
/// account to sync across since Phase 2 removed Firebase Auth.
class AppSettingsService {
  AppSettingsService._internal();
  static final AppSettingsService instance = AppSettingsService._internal();

  static const _keyThemeMode = 'theme_mode'; // 'light' | 'dark' | 'system'
  static const _keyLanguage = 'preferred_language';
  static const _keyFontScale = 'font_scale';

  /// Bounds for the app-wide text scale preference — kept in one place
  /// so the Bible screen's "Aa" control and Settings' quick entry can't
  /// drift out of sync with what's actually allowed.
  static const double minFontScale = 0.85;
  static const double maxFontScale = 1.6;
  static const double defaultFontScale = 1.0;

  Future<double> getFontScale() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getDouble(_keyFontScale) ?? defaultFontScale;
    // num.clamp() returns num, not double, even when called on a double
    // receiver — a well-known Dart gotcha. .toDouble() converts it back
    // so this actually matches its declared Future<double> return type.
    return value.clamp(minFontScale, maxFontScale).toDouble();
  }

  Future<void> setFontScale(double scale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
        _keyFontScale, scale.clamp(minFontScale, maxFontScale).toDouble());
  }

  Future<ThemeMode> getThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_keyThemeMode) ?? 'system';
    return _themeModeFromString(value);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyThemeMode, _themeModeToString(mode));
  }

  Future<String> getLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyLanguage) ?? 'english';
  }

  Future<void> setLanguage(String language) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLanguage, language);
  }

  ThemeMode _themeModeFromString(String value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  String _themeModeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }
}

/// Riverpod state for theme mode — read by MaterialApp.router, updated
/// from the Settings screen's dark/light/system toggle.
class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.system) {
    _load();
  }

  Future<void> _load() async {
    state = await AppSettingsService.instance.getThemeMode();
  }

  Future<void> setMode(ThemeMode mode) async {
    state = mode;
    await AppSettingsService.instance.setThemeMode(mode);
  }
}

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>(
  (ref) => ThemeModeNotifier(),
);

/// Riverpod state for the user's preferred language — drives default
/// selections across Bible, AI, and Live screens.
class LanguageNotifier extends StateNotifier<String> {
  LanguageNotifier() : super('english') {
    _load();
  }

  Future<void> _load() async {
    state = await AppSettingsService.instance.getLanguage();
  }

  Future<void> setLanguage(String language) async {
    state = language;
    await AppSettingsService.instance.setLanguage(language);
  }
}

final languageProvider = StateNotifierProvider<LanguageNotifier, String>(
  (ref) => LanguageNotifier(),
);

/// Riverpod state for the app-wide text scale preference — applied via
/// MaterialApp.router's `builder` in main.dart so it reaches every
/// screen, and exposed via a control on the Bible screen's app bar (an
/// "Aa" button) since older readers using this app for Scripture were
/// the specific, named reason for adding it — not tucked away as just
/// another line in Settings, though Settings also gets a quick entry
/// for discoverability.
class FontScaleNotifier extends StateNotifier<double> {
  FontScaleNotifier() : super(AppSettingsService.defaultFontScale) {
    _load();
  }

  Future<void> _load() async {
    state = await AppSettingsService.instance.getFontScale();
  }

  Future<void> setScale(double scale) async {
    final clamped = scale
        .clamp(
          AppSettingsService.minFontScale,
          AppSettingsService.maxFontScale,
        )
        .toDouble();
    state = clamped;
    await AppSettingsService.instance.setFontScale(clamped);
  }
}

final fontScaleProvider = StateNotifierProvider<FontScaleNotifier, double>(
  (ref) => FontScaleNotifier(),
);
