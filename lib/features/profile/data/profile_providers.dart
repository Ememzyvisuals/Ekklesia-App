import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../bible/data/bible_providers.dart' show appDatabaseProvider;
import 'profile_repository.dart';

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(ref.watch(appDatabaseProvider));
});
