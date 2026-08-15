import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'user_groq_key_service.dart';

/// The user's personal Groq key, if set. `autoDispose` + explicit
/// `ref.invalidate(userGroqKeyProvider)` after save/clear (see
/// settings_screen.dart) is what makes the Settings UI actually refresh —
/// a bare `FutureBuilder` re-calling `UserGroqKeyService.instance.getKey()`
/// on every rebuild looks like it would refresh too, but nothing in a
/// stateless/Consumer widget *triggers* a rebuild after a dialog closes,
/// so it was silently showing stale data until the screen was
/// re-entered. Routing through a provider gives an explicit invalidation
/// point instead of relying on an unrelated rebuild to happen to occur.
///
/// PROJECT_MIGRATION_AUDIT.md: groqRemainingTodayProvider removed — there
/// was a shared-quota concept it tracked (GroqUsageService), which no
/// longer exists now that every user brings their own key and there's no
/// proxy/shared tier to meter.
final userGroqKeyProvider = FutureProvider.autoDispose<String?>((ref) {
  return UserGroqKeyService.instance.getKey();
});
