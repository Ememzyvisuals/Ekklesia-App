import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the thing that actually breaks localization silently: someone
/// edits one language's ARB file and forgets the other four. `flutter
/// gen-l10n` doesn't always fail loudly for a missing key (it can fall
/// back to the template), so this is a deliberate, explicit check.
void main() {
  const languages = ['en', 'yo', 'ha', 'ig', 'pcm'];
  const templateLanguage = 'en'; // matches l10n.yaml's template-arb-file

  Map<String, dynamic> loadArb(String lang) {
    final file = File('lib/l10n/app_$lang.arb');
    return json.decode(file.readAsStringSync()) as Map<String, dynamic>;
  }

  test('every ARB file is valid JSON', () {
    for (final lang in languages) {
      expect(() => loadArb(lang), returnsNormally,
          reason: 'app_$lang.arb failed to parse as JSON');
    }
  });

  test('every language has exactly the same translation keys as the template',
      () {
    final templateKeys =
        loadArb(templateLanguage).keys.where((k) => !k.startsWith('@')).toSet();
    expect(templateKeys, isNotEmpty,
        reason:
            'Template ARB appears empty — check the test is finding the right file.');

    for (final lang in languages) {
      if (lang == templateLanguage) continue;
      final keys = loadArb(lang).keys.where((k) => !k.startsWith('@')).toSet();
      final missing = templateKeys.difference(keys);
      final extra = keys.difference(templateKeys);
      expect(missing, isEmpty,
          reason:
              'app_$lang.arb is missing keys present in the template: $missing');
      expect(extra, isEmpty,
          reason: 'app_$lang.arb has keys not present in the template: $extra');
    }
  });

  test('no translation value is an empty string', () {
    for (final lang in languages) {
      final data = loadArb(lang);
      for (final entry in data.entries) {
        if (entry.key.startsWith('@')) continue;
        expect(
          entry.value,
          isNot(equals('')),
          reason: 'app_$lang.arb has an empty value for key "${entry.key}"',
        );
      }
    }
  });

  test('@@locale matches the filename for every ARB file', () {
    for (final lang in languages) {
      final data = loadArb(lang);
      expect(data['@@locale'], lang,
          reason: 'app_$lang.arb\'s @@locale doesn\'t match its filename');
    }
  });
}
