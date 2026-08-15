# Action Workflow

Numbered path from a fresh clone of this repository to a submittable
build. Each step: objective, commands, expected result, what to do if it
fails. Nothing below has been executed in the sandbox this repo was
built in — every step is a real next action, not a confirmed-working one.

---

### 1. Install dependencies

**Objective**: get a compiling dependency graph.
**Commands**: `flutter pub get`
**Expected result**: resolves without version conflicts.
**If it fails**: check `pubspec.yaml` constraints — several dependencies
(`isar`, `cloud_functions`, `riverpod_generator`) were added across
sessions and haven't been resolved together by an actual `pub get` before.

---

### 2. Generate code

**Objective**: produce the `.g.dart` files every `@collection` class needs.
**Commands**: `flutter pub run build_runner build --delete-conflicting-outputs`
**Expected result**: `lib/features/bible/data/*_schema.g.dart` files appear.
**If it fails**: this is genuinely untested — read the actual error.
Common Isar codegen issues: a field type it doesn't support, or a
missing `part 'x.g.dart';` directive (all schema files in this repo
already have one — check for typos in the filename match).

---

### 3. Generate localization

**Objective**: produce `AppLocalizations` getters for every ARB key.
**Commands**: `flutter gen-l10n`
**Expected result**: `lib/l10n/generated/app_localizations.dart` exists.
**Verification**: run `flutter test test/l10n/arb_parity_test.dart` first
— if that fails, gen-l10n will likely also fail or silently fall back
for the mismatched language.

---

### 4. Firebase project setup

**Objective**: a real backend to point the app at.
**Commands/files**: see `FIREBASE_SETUP.md` in full.
**Expected result**: `lib/firebase_options.dart` exists (from
`flutterfire configure`), functions deployed, secrets set, rules/indexes
deployed.
**Recovery if secrets are wrong**: `firebase functions:secrets:set
GROQ_API_KEY` / `YOUTUBE_API_KEY` again — Cloud Functions read secrets
at cold-start, so redeploy (`firebase deploy --only functions`) after
changing a secret's value.

---

### 5. Generate platform folders

**Objective**: `android/` and `ios/` need to exist to build anything.
**Commands**: `flutter create .`
**Expected result**: both folders appear without touching `lib/`.
**Then**: apply platform-specific config per `DEPLOYMENT_GUIDE.md` §2
(icons, signing, Firebase config files) — none of this exists yet.

---

### 6. Run locally

**Objective**: confirm the app actually launches.
**Commands**: `flutter run`
**Expected result**: app opens to onboarding (fresh install) or Home
(signed-in). If it crashes on launch, check `main.dart`'s startup
sequence order first — `IsarService.instance.open()` must complete
before any widget reads `isarProvider`.

---

### 7. Manual feature verification

**Objective**: confirm the features documented as "done" actually work
end-to-end against your real backend.
**Commands/checks**: work through every row of
`DEVELOPER_VERIFICATION_GUIDE.md`'s feature table.
**If Bible import fails**: check that `assets/bible/*.json` are actually
bundled (pubspec `assets:` section, already configured — but confirm
the files exist on disk at that path).
**If AI chat fails**: check `wrangler tail` on the `groq-proxy` Worker
(not `firebase functions:log` — Groq no longer runs through a Cloud
Function) — most likely cause is a missing/misnamed `GROQ_API_KEY`
Worker secret (`wrangler secret put GROQ_API_KEY`).

---

### 8. Automated checks

**Objective**: everything CI would check, run locally first.
**Commands**: `flutter analyze && flutter test && dart format --set-exit-if-changed .`
**Expected result**: all clean/passing.
**If `flutter analyze` finds issues**: fix them — this codebase has
never actually been analyzed by a real Dart analyzer; expect some real
findings on the first run, most likely minor (unused imports, missing
`const`), not architectural.

---

### 9. Build release artifacts

**Objective**: a submittable APK/AAB/IPA.
**Commands**: see `DEPLOYMENT_GUIDE.md` §3.

---

### 10. Release checklist

**Objective**: everything that isn't a code problem but will still block
submission.
**Commands**: work through `RELEASE_CHECKLIST.md` fully — several items
(privacy policy, app icon, native-speaker translation QA) are not
optional for store approval.

---

### 11. Submit

Store-specific steps, intentionally not detailed here — see
`DEPLOYMENT_GUIDE.md`'s closing note on why.
