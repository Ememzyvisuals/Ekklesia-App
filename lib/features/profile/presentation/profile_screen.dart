import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_theme.dart';
import '../../auth/data/avatar_service.dart';
import '../../auth/presentation/avatar_picker.dart';
import '../data/profile_providers.dart';
import '../data/profile_repository.dart';

/// PROJECT_MIGRATION_AUDIT.md Phase 2: no more Firebase user doc, no
/// "Sign out" (there's no account to sign out of), no email, no photo
/// upload/bio fields (not part of the spec's local-onboarding field
/// list — displayName/ageGroup/gender/preferredLanguage/avatarId only).
/// Editing here writes straight to the local Drift-backed profile.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  Future<void> _editDisplayName(LocalProfile profile) async {
    final controller = TextEditingController(text: profile.displayName);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit name'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await ref
          .read(profileRepositoryProvider)
          .update(displayName: result);
    }
  }

  Future<void> _editAvatar(LocalProfile profile) async {
    final gender =
        profile.gender == 'female' ? AvatarGender.female : AvatarGender.male;
    await showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: AvatarPicker(
          initialGender: gender,
          selectedId: profile.avatarId,
          onSelected: (option) async {
            await ref
                .read(profileRepositoryProvider)
                .update(avatarId: option.id);
            if (context.mounted) Navigator.pop(context);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: StreamBuilder<LocalProfile?>(
        stream: ref.watch(profileRepositoryProvider).watch(),
        builder: (context, snapshot) {
          final profile = snapshot.data;
          if (profile == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Center(
                child: GestureDetector(
                  onTap: () => _editAvatar(profile),
                  child: Stack(
                    children: [
                      AvatarView(avatarId: profile.avatarId, size: 96),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                              color: AppColors.accent, shape: BoxShape.circle),
                          child: const Icon(Icons.edit,
                              size: 16, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(profile.displayName,
                    style: AppTypography.titleLarge(
                        color: AppTheme.textPrimary(context))),
              ),
              const SizedBox(height: 24),
              ListTile(
                title: const Text('Display name'),
                subtitle: Text(profile.displayName),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _editDisplayName(profile),
              ),
              ListTile(
                title: const Text('Age group'),
                subtitle: Text(profile.ageGroup),
              ),
              ListTile(
                title: const Text('Preferred language'),
                subtitle: Text(profile.preferredLanguage),
              ),
            ],
          );
        },
      ),
    );
  }
}
