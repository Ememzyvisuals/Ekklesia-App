import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/config/app_theme.dart';
import '../../../core/config/app_router.dart' show onboardingSeenCache;
import '../../../core/services/app_settings_service.dart';
import '../../auth/data/avatar_service.dart';
import '../../profile/data/profile_providers.dart';

const _onboardingSeenKey = 'onboarding_seen';

Future<bool> hasSeenOnboarding() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_onboardingSeenKey) ?? false;
}

/// First-run flow: welcome + a language choice (drives default TTS/Bible
/// language across the app via [languageProvider]). Shown once; skipped
/// on subsequent launches via the SharedPreferences flag above, checked
/// by the router's redirect logic.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  final _nameController = TextEditingController();
  int _page = 0;
  String _selectedLanguage = 'english';
  String _ageGroup = '18-24';
  AvatarGender _gender = AvatarGender.male;
  String? _selectedAvatarId;
  bool _saving = false;
  String? _error;

  static const _languages = [
    ('english', 'English'),
    ('yoruba', 'Yorùbá'),
    ('hausa', 'Hausa'),
    ('igbo', 'Igbo'),
    ('pidgin', 'Pidgin'),
  ];

  static const _ageGroups = ['13-17', '18-24', '25-34', '35-49', '50+'];

  @override
  void dispose() {
    _nameController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final displayName = _nameController.text.trim().isEmpty
          ? 'Friend'
          : _nameController.text.trim();
      // If the user didn't pick a specific avatar, assign one
      // deterministically from gender + name, same "generate a default
      // illustrated avatar" requirement the old Firebase signup honored —
      // just seeded from the name typed here instead of a uid that no
      // longer exists.
      final avatarId = _selectedAvatarId ??
          AvatarService.instance
              .pickDefault(gender: _gender, seed: displayName)
              .id;

      await ref.read(profileRepositoryProvider).create(
            displayName: displayName,
            ageGroup: _ageGroup,
            gender: _gender.name,
            preferredLanguage: _selectedLanguage,
            avatarId: avatarId,
          );

      await ref.read(languageProvider.notifier).setLanguage(_selectedLanguage);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_onboardingSeenKey, true);
      onboardingSeenCache = true;
      if (mounted) context.go('/home');
    } catch (e) {
      setState(() => _error = 'Could not save your profile: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  const _WelcomePage(
                    title: 'Welcome to Ekklesia',
                    subtitle: 'Sermons, Bible study, and an AI companion for '
                        'DCLM members and Christians everywhere — in your '
                        'own language.',
                    icon: Icons.church,
                  ),
                  const _WelcomePage(
                    title: 'Listen Anywhere',
                    subtitle: 'DCLM radio and messages keep playing even '
                        'when your screen locks.',
                    icon: Icons.radio,
                  ),
                  _LanguagePage(
                    selected: _selectedLanguage,
                    languages: _languages,
                    onSelect: (code) =>
                        setState(() => _selectedLanguage = code),
                  ),
                  _ProfilePage(
                    nameController: _nameController,
                    ageGroup: _ageGroup,
                    ageGroups: _ageGroups,
                    onAgeGroupSelect: (v) => setState(() => _ageGroup = v),
                    gender: _gender,
                    onGenderSelect: (v) => setState(() {
                      _gender = v;
                      _selectedAvatarId =
                          null; // re-pick default for new gender
                    }),
                    selectedAvatarId: _selectedAvatarId,
                    onAvatarSelect: (id) =>
                        setState(() => _selectedAvatarId = id),
                    error: _error,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  Row(
                    children: List.generate(
                        4,
                        (i) => Container(
                              margin: const EdgeInsets.only(right: 6),
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i == _page
                                    ? AppColors.primary
                                    : AppColors.primary.withValues(alpha: 0.2),
                              ),
                            )),
                  ),
                  const Spacer(),
                  if (_page > 0)
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => _pageController.previousPage(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeOut),
                      child: const Text('Back'),
                    ),
                  ElevatedButton(
                    onPressed: _saving
                        ? null
                        : () {
                            if (_page < 3) {
                              _pageController.nextPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOut,
                              );
                            } else {
                              _finish();
                            }
                          },
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_page < 3 ? 'Next' : 'Get Started'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage(
      {required this.title, required this.subtitle, required this.icon});
  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 96, color: AppColors.primary),
          const SizedBox(height: 32),
          Text(title,
              style: Theme.of(context).textTheme.headlineMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary(context))),
        ],
      ),
    );
  }
}

class _ProfilePage extends StatelessWidget {
  const _ProfilePage({
    required this.nameController,
    required this.ageGroup,
    required this.ageGroups,
    required this.onAgeGroupSelect,
    required this.gender,
    required this.onGenderSelect,
    required this.selectedAvatarId,
    required this.onAvatarSelect,
    this.error,
  });

  final TextEditingController nameController;
  final String ageGroup;
  final List<String> ageGroups;
  final void Function(String) onAgeGroupSelect;
  final AvatarGender gender;
  final void Function(AvatarGender) onGenderSelect;
  final String? selectedAvatarId;
  final void Function(String) onAvatarSelect;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final avatars =
        AvatarService.catalog.where((a) => a.gender == gender);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Tell us about you',
              style: Theme.of(context).textTheme.headlineMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text('No account needed — this stays on your device.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary(context))),
          const SizedBox(height: 24),
          TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: 'Display name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          Text('Age group', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ageGroups
                .map((g) => ChoiceChip(
                      label: Text(g),
                      selected: ageGroup == g,
                      onSelected: (_) => onAgeGroupSelect(g),
                    ))
                .toList(),
          ),
          const SizedBox(height: 20),
          Text('Gender', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: AvatarGender.values
                .map((g) => ChoiceChip(
                      label: Text(g == AvatarGender.male ? 'Male' : 'Female'),
                      selected: gender == g,
                      onSelected: (_) => onGenderSelect(g),
                    ))
                .toList(),
          ),
          const SizedBox(height: 20),
          Text('Choose an avatar (optional)',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SizedBox(
            height: 72,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: avatars
                  .map((a) => Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: InkWell(
                          onTap: () => onAvatarSelect(a.id),
                          borderRadius: BorderRadius.circular(36),
                          child: CircleAvatar(
                            radius: 32,
                            backgroundColor: selectedAvatarId == a.id
                                ? AppColors.primary.withValues(alpha: 0.15)
                                : AppTheme.surface(context),
                            child: CircleAvatar(
                              radius: 28,
                              backgroundImage: AssetImage(a.assetPath),
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 16),
            Text(error!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
    );
  }
}

class _LanguagePage extends StatelessWidget {
  const _LanguagePage(
      {required this.selected,
      required this.languages,
      required this.onSelect});
  final String selected;
  final List<(String, String)> languages;
  final void Function(String) onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Choose your language',
              style: Theme.of(context).textTheme.headlineMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text('You can change this anytime in Settings',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary(context))),
          const SizedBox(height: 24),
          ...languages.map((l) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  onTap: () => onSelect(l.$1),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: selected == l.$1
                          ? AppColors.primary.withValues(alpha: 0.1)
                          : AppTheme.surface(context),
                      border: Border.all(
                          color: selected == l.$1
                              ? AppColors.primary
                              : Colors.transparent,
                          width: 2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Text(l.$2,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        const Spacer(),
                        if (selected == l.$1)
                          const Icon(Icons.check_circle,
                              color: AppColors.primary),
                      ],
                    ),
                  ),
                ),
              )),
        ],
      ),
    );
  }
}
