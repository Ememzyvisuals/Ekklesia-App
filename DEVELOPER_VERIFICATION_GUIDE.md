# Developer Verification Guide

Manual verification steps for a fresh environment — none of this has
been run in the sandbox this was built in (no Flutter SDK, no live
Firebase project). Treat every step here as unverified until you've
actually run it once.

## Environment setup

1. `flutter --version` — confirm a recent stable Flutter is installed.
2. `flutter pub get` — expected result: resolves cleanly. If it doesn't,
   check `pubspec.yaml` version constraints before assuming the code is
   the problem.
3. `flutter pub run build_runner build --delete-conflicting-outputs` —
   expected result: generates `.g.dart` files for every `@collection`
   class (see `DATABASE_SCHEMA.md`'s Isar table) and Riverpod/Freezed
   equivalents if any are added later. **This has never been run against
   this codebase** — if it fails, that's the single most likely first
   real bug to hit, not a sign the surrounding Dart code is wrong.
4. `flutter gen-l10n` — expected result: generates
   `lib/l10n/generated/app_localizations.dart` with getters for every key
   in `lib/l10n/app_en.arb`. Cross-check against `test/l10n/arb_parity_test.dart`
   passing first.

## Firebase

Follow `FIREBASE_SETUP.md` in full first. Then:

5. `firebase functions:log` after deploying — confirm each scheduled
   function's first run doesn't error immediately (missing secret,
   permission issue).

## Feature-by-feature manual checks

| Feature | Check | Expected result |
|---|---|---|
| Bible import | Open Bible tab, pick a language not yet imported, tap Import | Snackbar confirms import; book list populates; reopening the tab shows the reader directly (no re-import prompt) |
| Bible reading | Navigate Genesis → 1 | 31 verses render, verse 1 text matches KJV for English |
| Bible reference jump | Type "John 3:16", tap search | Jumps directly to John chapter 3, scrolled/rendered with verse 16 visible |
| Bible search | Type a common word (e.g. "love") | Results list populates from the currently selected Bible language, tapping a result opens that chapter |
| Bible highlight | Long-press a verse, tap a color | Verse background changes color immediately; reopening the chapter later still shows it |
| Bible note | Long-press a verse, tap Note, type, Save | Reopening the note dialog later shows the saved text |
| Continue Reading | Open a chapter, go back to book list | A "Continue Reading" card appears pointing at that chapter |
| Reading streak | Open any chapter | Streak banner appears/increments (only once per calendar day) |
| Bible audio | Tap Listen on a chapter | Audio plays; tapping Listen again on the *same* chapter plays near-instantly (cache hit) — check via a stopwatch, first play should be noticeably slower than the second |
| AI chat | Sign in, send a message in AI Assistant | A real Groq-generated reply appears — this exercises the `groq-proxy` Cloudflare Worker end-to-end |
| Sermons refresh | Pull to refresh on Sermons screen | New/updated videos appear if DCLM has uploaded since the `youtube-sync` Worker's Cron Trigger last ran — the pull-to-refresh itself exercises its `/syncNow` endpoint |
| Localization | Switch app language in Settings, revisit Bible screen | Every string on screen changes language, including the ones added this pass (import prompt, search hint, streak text, etc.) |

## Known-unverified items (flag these explicitly if you find issues)

- Whether the app compiles at all (see step 3 above).
- Whether the `groq-proxy`/`youtube-sync` Cloudflare Workers actually
  work against a live deployment and a real Firebase project — code is
  internally consistent but untested. The YouTube Worker's hand-rolled
  service-account OAuth2 flow is the riskiest piece.
- Whether the 6 GitHub Actions workflows actually pass.
