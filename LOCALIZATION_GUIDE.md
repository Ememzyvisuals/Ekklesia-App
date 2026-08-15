# Localization Guide

5 languages: English (`en`), Yoruba (`yo`), Hausa (`ha`), Igbo (`ig`),
Nigerian Pidgin (`pcm`). Template is `en` (`l10n.yaml`'s
`template-arb-file: app_en.arb`).

## Adding a new string

1. Add the key to **`lib/l10n/app_en.arb`** first — this is the template;
   every other file's key set must match it exactly (see
   `test/l10n/arb_parity_test.dart`, which fails the build if they don't).
2. Add the same key, translated, to all four other ARB files
   (`app_yo.arb`, `app_ha.arb`, `app_ig.arb`, `app_pcm.arb`).
3. Run `flutter gen-l10n` (or just `flutter run`/`flutter pub get` if
   `generate: true` is set — check `pubspec.yaml`) to regenerate
   `lib/l10n/generated/app_localizations.dart`.
4. Use it: `AppLocalizations.of(context)!.yourNewKey`.

## Placeholders

```json
"bibleStreakDays": "{days}-day reading streak"
```

No explicit `@key` metadata block was added for most placeholders added
this pass (e.g. `bibleStreakDays`, `bibleImportPrompt`) — `flutter
gen-l10n` infers an `Object`-typed parameter by default when there's no
explicit type declared, which still works correctly (Dart's string
interpolation calls `toString()`), it's just less strict than declaring
`"@bibleStreakDays": {"placeholders": {"days": {"type": "int"}}}`. Fine
for now; tightening this is a small, safe follow-up if it ever matters.

## Translation quality note — read this before assuming translations are perfect

The Yoruba, Hausa, and Igbo translations across this app (including
everything added this pass) have **not been verified by a native
speaker**. They're written to be simple, grammatically reasonable, and
consistent with the existing file's vocabulary/register — not verified
against a fluent reviewer. Nigerian Pidgin translations are more
confidently correct (closer to English, easier to verify by inspection),
but still worth a native read-through before shipping. Treat all four
non-English languages as "good faith, needs QA," not "verified correct."

## Screens not yet localized

As of this pass, every screen has been checked and localized except
where noted otherwise in `FINAL_AUDIT_REPORT.md` — if you find a screen
with hardcoded English strings, that's real remaining work, not
something already tracked; add it to that report's Technical Debt
section when found.
