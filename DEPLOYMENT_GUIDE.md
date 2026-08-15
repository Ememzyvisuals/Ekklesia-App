# Deployment Guide

This assumes `FIREBASE_SETUP.md` is already done (project created,
functions deployed, secrets set, rules/indexes deployed).

## 1. Local build prerequisites (do this first, once)

```
flutter pub get
flutter pub run build_runner build --delete-conflicting-outputs
flutter create .        # generates android/ and ios/ — don't skip this
```

`flutter create .` on an existing project fills in the missing platform
folders without touching `lib/`. Confirm `pubspec.yaml`'s `name:` matches
what you want as the generated package/bundle identifier, or plan to
change it in the generated `android/app/build.gradle` /
`ios/Runner.xcodeproj` afterward.

## CI-generated platform folders (updated this pass)

`release.yml` now runs `flutter create . --platforms=android,ios` itself,
on the GitHub Actions runner (which has a real Flutter SDK via
`subosito/flutter-action`) — so `android/`/`ios/` don't need to exist in
the repo at all for CI release builds. This is different from generating
them by hand in an environment with no SDK to verify against (see
`FINAL_AUDIT_REPORT.md` for why that wasn't done); a CI runner's SDK
makes this safe and standard.

For a **properly signed** release build (not just a debug-signed one
that builds fine but Play Console will reject), set these repository
secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -i your-release-key.jks \| pbcopy` (or equivalent) — the whole keystore file, base64-encoded |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | Key alias |
| `ANDROID_KEY_PASSWORD` | Key password (often same as keystore password) |

If these aren't set, the workflow still builds successfully — just
debug-signed, which is fine for internal testing but not for a Play
Store submission.

**Worth knowing before trusting this blindly**: the workflow patches
`android/app/build.gradle` (or `.gradle.kts`, it checks for both) with a
small Python script to wire the release `signingConfig` to the secrets
above, matching Flutter's standard generated template as of this pass.
Flutter's templates do change between versions — if a future Flutter
upgrade changes that file's structure, this patch step may need
updating. Verify the first real run's logs show "Patched ... with
release signing config" rather than silently doing nothing.

## Manual platform config still needed after CI's flutter create

**Why this doc doesn't include hand-written `android/`/`ios/` folders:**
Android's side (Gradle files, `AndroidManifest.xml`, Kotlin
`MainActivity`) is plain, stable text that could reasonably be
hand-written. iOS's side is not — `ios/Runner.xcodeproj/project.pbxproj`
encodes an actual build graph via internal UUID references between
targets, build phases, and file groups; a hand-written one that looks
plausible but has one wrong reference produces a project that won't open
in Xcode at all, which is worse than not having one — it looks done and
isn't. `flutter create .` is what correctly generates both from the
official templates for whatever Flutter version you have installed
(these templates change with Flutter/Gradle/Xcode versions, so a
hand-written copy would also drift stale over time in a way `flutter
create .` doesn't). Run that first:

```
flutter create .
```

This fills in `android/` and `ios/` without touching `lib/`.

### What to add afterward, and why — based on what this app's dependencies actually need

Two dependencies require real platform configuration beyond
`flutter create .`'s defaults: `just_audio_background` (background Bible
audio / radio playback) and `firebase_messaging` (push notifications, via
`notification_service.dart`). Both are already real dependencies in
`pubspec.yaml` and already used in `lib/main.dart` /
`lib/core/services/notification_service.dart` — this isn't speculative,
it's what the actual code needs to work correctly on a real device.

**Android** (`android/app/src/main/AndroidManifest.xml`):
```xml
<manifest ...>
  <uses-permission android:name="android.permission.INTERNET" />
  <!-- Android 13+ requires this for any notification to show at all -->
  <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
  <!-- Android 14+ requires declaring the foreground service type explicitly -->
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />

  <application ...>
    <!-- just_audio_background's required service for background/lock-screen playback -->
    <service
        android:name="com.ryanheise.audioservice.AudioService"
        android:foregroundServiceType="mediaPlayback"
        android:exported="true">
      <intent-filter>
        <action android:name="android.media.browse.MediaBrowserService" />
      </intent-filter>
    </service>
    <receiver
        android:name="com.ryanheise.audioservice.MediaButtonReceiver"
        android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MEDIA_BUTTON" />
      </intent-filter>
    </receiver>
  </application>
</manifest>
```
Also add `google-services.json` (from Firebase console) to
`android/app/`, and apply the Google Services Gradle plugin per
`flutterfire configure`'s own instructions (it usually edits this for
you — verify it did).

**iOS** (`ios/Runner/Info.plist`):
```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
  <string>fetch</string>
  <string>remote-notification</string>
</array>
```
Then in Xcode (not a plain-text file, has to be done there): Runner
target → Signing & Capabilities → add "Background Modes" (check Audio,
Background fetch, Remote notifications — matching the plist above) and
"Push Notifications". Add `GoogleService-Info.plist` (from Firebase
console) to the `Runner` target.

**Both platforms**: no camera/microphone/location permission entries are
needed — nothing in this codebase as of this pass uses any of those.

## 3. App icon, package name, and signing

- **App icon**: `assets/icons`/`assets/images` are currently empty (see
  `FINAL_AUDIT_REPORT.md`'s technical debt note) — get real icon assets
  first, then generate platform icons with a tool like
  `flutter_launcher_icons` rather than hand-placing resized PNGs into
  `android/app/src/main/res/mipmap-*` / `ios/Runner/Assets.xcassets`
  yourself.
- **Package name / bundle identifier**: `flutter create .` uses
  `pubspec.yaml`'s `name:` as a starting point, but confirm the actual
  Android `applicationId` (`android/app/build.gradle`) and iOS bundle
  identifier (Xcode → Runner target → General) are the real,
  store-registered identifiers before your first release build — these
  can't be changed after a store listing is created without shipping as
  a new app.
- **Signing**: Android needs a real keystore + `android/key.properties`
  (never commit either — add both to `.gitignore` if not already
  covered). iOS needs a signing team/certificate set in Xcode. Neither
  exists yet since platform folders don't exist yet.

## 4. Build

```
flutter build apk --release        # or --appbundle for Play Store
flutter build ios --release        # then archive via Xcode
```

## 5. Before submitting to app stores

Run through `RELEASE_CHECKLIST.md` — don't skip straight to store
submission from a build that compiles; several of that checklist's items
(privacy policy text, permission justifications, screenshots) are
store-review blockers that have nothing to do with whether the code
works.

## What this guide does NOT cover

- Actual app-store-specific submission steps (Play Console / App Store
  Connect UI walkthroughs) — those change often enough that a static doc
  here would go stale fast; use the platforms' own current docs at
  submission time.
- CI/CD auto-deployment — the 6 GitHub Actions workflows in
  `.github/workflows/` handle analyze/test/dependency-check/security-scan
  and have a `release.yml`, but none of this has been run against real CI
  in this sandbox (no Flutter SDK here) — verify it actually passes
  before trusting it as a gate.
