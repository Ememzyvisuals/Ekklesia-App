import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../bible/data/bible_providers.dart' show appDatabaseProvider;
import 'bookmark_repository.dart';

final bookmarkRepositoryProvider = Provider<BookmarkRepository>((ref) {
  return BookmarkRepository(ref.watch(appDatabaseProvider));
});
