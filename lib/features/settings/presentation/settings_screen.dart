import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/ai_config.dart';
import '../../../core/services/app_settings_service.dart';
import '../../../core/services/groq_providers.dart';
import '../../../core/services/user_groq_key_service.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../core/config/app_theme.dart';
import '../../../core/config/app_config.dart';
import '../../profile/data/profile_providers.dart';
import '../../profile/data/profile_repository.dart';
import '../../bible/presentation/voice_download_sheet.dart';

/// Real settings screen — theme mode, language, voice engine info, sign
/// out, downloads management, and notifications. Credits is still listed
/// but not built out (flagged, not silently skipped).
/// No accounts left to sign out of (PROJECT_MIGRATION_AUDIT.md Phase 2) —
/// this screen now shows the local profile instead of a Firebase user,
/// and the old "Sign Out" tile is gone entirely rather than pointing
/// somewhere that no longer exists.
final _localProfileStreamProvider = StreamProvider<LocalProfile?>((ref) {
  return ref.watch(profileRepositoryProvider).watch();
});

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  // Voice descriptors updated for Phase 5 (on-device TTS) — previously
  // named the cloud engines (WazobiaVoice/YarnGPT-local), both removed.
  // Igbo explicitly marked as having no voice rather than silently
  // implying one exists — see AppConfig.mmsOnnxRepoBaseUrl's doc comment
  // for the full record of what was tried.
  static const _languages = [
    ('english', 'English (device voice)'),
    ('hausa', 'Hausa (offline voice, download required)'),
    ('igbo', 'Igbo (no voice available)'),
    ('pidgin', 'Pidgin (offline voice, download required)'),
    ('yoruba', 'Yoruba (offline voice, download required)'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final themeMode = ref.watch(themeModeProvider);
    final language = ref.watch(languageProvider);
    final user = ref.watch(_localProfileStreamProvider).value;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.navSettings)),
      body: ListView(
        children: [
          if (user != null)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(user.displayName),
              subtitle: Text(user.preferredLanguage),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/profile'),
            ),
          const Divider(),

          ListTile(
            leading: const Icon(Icons.videogame_asset_outlined),
            title: Text(l10n.settingsGames),
            subtitle: Text(l10n.settingsGamesSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/games'),
          ),
          const Divider(),

          ListTile(
            leading: const Icon(Icons.record_voice_over_outlined),
            title: const Text('Offline voices'),
            subtitle: const Text(
                'Download or remove on-device Bible narration voices'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (context) => const VoiceDownloadSheet(),
            ),
          ),
          const Divider(),

          ListTile(
            leading: const Icon(Icons.language),
            title: Text(l10n.settingsLanguageVoice),
            subtitle: Text(_languages
                .firstWhere((l) => l.$1 == language,
                    orElse: () => _languages.first)
                .$2),
            onTap: () => _showLanguagePicker(context, ref, language),
          ),

          const Divider(),
          ListTile(
            leading: const Icon(Icons.smart_toy_outlined),
            title: Text(l10n.settingsAiSectionTitle),
          ),
          FutureBuilder<String?>(
            future: ref.watch(userGroqKeyProvider.future),
            builder: (context, snapshot) {
              final key = snapshot.data;
              return ListTile(
                leading: Icon(
                    key != null ? Icons.key_rounded : Icons.key_off_outlined),
                title: Text(l10n.settingsGroqKeyTitle),
                subtitle: key != null
                    ? Text(l10n.settingsGroqKeyUnlimitedSuffix(
                        UserGroqKeyService.mask(key)))
                    : Text(l10n.settingsGroqKeyRequired),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    _showGroqKeyDialog(context, ref, l10n, currentKey: key),
              );
            },
          ),

          const Divider(),
          ListTile(
            leading: const Icon(Icons.text_fields),
            title: const Text('Text size'),
            subtitle: Text('${(ref.watch(fontScaleProvider) * 100).round()}% — applies app-wide'),
            trailing: const Icon(Icons.chevron_right),
            // Same control as the Bible screen's "Aa" button — added
            // here too since not everyone will find it on the Bible
            // screen first, and the specific request mentioned "or
            // generally the application" as an acceptable alternative
            // to a Bible-only setting.
            onTap: () => showModalBottomSheet(
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
            ),
          ),

          const Divider(),
          ListTile(
            leading: const Icon(Icons.brightness_6),
            title: Text(l10n.settingsAppearance),
          ),
          // RadioGroup ancestor replaces RadioListTile's own groupValue/
          // onChanged — those were deprecated in Flutter 3.32 in favor of
          // this pattern, which is what dart analyze was flagging
          // (deprecated_member_use x6, two per tile x3 tiles). The tiles
          // below now only declare `value:`; the group-level selection
          // state and the change callback both live on RadioGroup itself.
          RadioGroup<ThemeMode>(
            groupValue: themeMode,
            onChanged: (m) => ref.read(themeModeProvider.notifier).setMode(m!),
            child: Column(
              children: [
                RadioListTile<ThemeMode>(
                  title: Text(l10n.settingsThemeSystem),
                  value: ThemeMode.system,
                ),
                RadioListTile<ThemeMode>(
                  title: Text(l10n.settingsThemeLight),
                  value: ThemeMode.light,
                ),
                RadioListTile<ThemeMode>(
                  title: Text(l10n.settingsThemeDark),
                  value: ThemeMode.dark,
                ),
              ],
            ),
          ),

          const Divider(),
          ListTile(
            leading: const Icon(Icons.download),
            title: Text(l10n.settingsDownloads),
            subtitle: Text(l10n.settingsDownloadsSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/downloads'),
          ),
          ListTile(
            leading: const Icon(Icons.notifications),
            title: Text(l10n.settingsNotifications),
            subtitle: Text(l10n.settingsNotificationsSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/notifications'),
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: Text(l10n.settingsBookmarks),
            subtitle: Text(l10n.settingsBookmarksSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/bookmarks'),
          ),
          ListTile(
            leading: const Icon(Icons.network_check),
            title: const Text('Network Diagnostics'),
            subtitle: const Text('Test connectivity to each app service'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/network-diagnostics'),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(l10n.settingsCredits),
            subtitle: Text(l10n.settingsCreditsSubtitle),
          ),
          // Lets the person testing a build and the developer confirm
          // they're both looking at the same code, without a round of
          // "did you rebuild?" guessing — added after several rounds of
          // TTS/Radio bug reports kept showing literally identical error
          // text with no fast way to tell whether that meant a fix
          // hadn't worked or an old APK was still what got tested.
          ListTile(
            leading: const Icon(Icons.build_outlined),
            title: const Text('Build'),
            subtitle: Text(AppConfig.buildTag),
          ),
        ],
      ),
    );
  }

  void _showLanguagePicker(
      BuildContext context, WidgetRef ref, String current) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _languages
              .map((l) => ListTile(
                    title: Text(l.$2),
                    trailing: current == l.$1
                        ? const Icon(Icons.check, color: AppColors.primary)
                        : null,
                    onTap: () {
                      ref.read(languageProvider.notifier).setLanguage(l.$1);
                      Navigator.of(context).pop();
                    },
                  ))
              .toList(),
        ),
      ),
    );
  }

  void _showGroqKeyDialog(
      BuildContext context, WidgetRef ref, AppLocalizations l10n,
      {String? currentKey}) {
    final controller = TextEditingController();
    var obscure = true;
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(l10n.settingsGroqKeyTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  currentKey != null
                      ? l10n.settingsGroqKeyDialogCurrentSet(
                          UserGroqKeyService.mask(currentKey))
                      : l10n.settingsGroqKeyDialogPrompt,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    hintText: 'gsk_...',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: IconButton(
                      icon: Icon(obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined),
                      onPressed: () => setDialogState(() => obscure = !obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                InkWell(
                  onTap: () =>
                      launchUrl(Uri.parse('https://console.groq.com/keys')),
                  child: const Text(
                    'console.groq.com/keys',
                    style: TextStyle(
                        color: AppColors.primary,
                        decoration: TextDecoration.underline),
                  ),
                ),
              ],
            ),
            actions: [
              if (currentKey != null)
                TextButton(
                  onPressed: () async {
                    // PROJECT_MIGRATION_AUDIT.md: clearing the key used to
                    // just fall back to a shared free tier — now it means
                    // AI features stop working entirely (no fallback left
                    // at all), so this needs a real confirmation, not a
                    // silent one-tap clear.
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Remove Groq key?'),
                        content: const Text(
                            'AI features will stop working until you add a key again.'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: Text(l10n.commonCancel),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: Text(l10n.settingsGroqKeyRemove),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true) return;
                    await UserGroqKeyService.instance.clearKey();
                    ref.invalidate(userGroqKeyProvider);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: Text(l10n.settingsGroqKeyRemove),
                ),
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.commonCancel)),
              FilledButton(
                onPressed: () async {
                  final value = controller.text.trim();
                  if (value.isEmpty) {
                    Navigator.pop(context);
                    return;
                  }
                  await UserGroqKeyService.instance.setKey(value);
                  ref.invalidate(userGroqKeyProvider);
                  // Was missing entirely — AIConfig.verify() only ever
                  // ran once, at app startup, before this key existed.
                  // Confirmed on a real device: adding a valid key here
                  // still produced "something went wrong" on every AI
                  // request afterward, because the model selection
                  // AIConfig computed at boot (with no key at all) was
                  // never recomputed. Not awaited — Settings shouldn't
                  // block on a network round trip just to close this
                  // dialog; the AI screen's own request path already
                  // has its own timeout/retry handling.
                  unawaited(AIConfig.instance.verify());
                  if (context.mounted) Navigator.pop(context);
                },
                child: Text(l10n.commonSave),
              ),
            ],
          );
        },
      ),
    );
  }
}
