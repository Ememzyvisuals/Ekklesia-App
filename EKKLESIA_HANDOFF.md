# Ekklesia App — Project Handoff & Debugging Log

**Purpose of this document:** This is a complete working record of everything
done on this project so far, written so a fresh Claude session (or any
developer) can pick up exactly where things left off — no re-diagnosing
things already solved, no re-introducing bugs already fixed.

**How to use this doc:** Upload this file alongside a fresh download of the
GitHub repo. Read the "Workflow Pattern" section first — it's the exact
operating procedure this project runs on and must keep running on, since the
developer works entirely from a phone (Termux + GitHub Actions, no local
Flutter SDK, no computer).

---

## 0. Project Basics

- **Repo:** `Ememzyvisuals/Ekklesia-App` on GitHub (public repo)
- **Owner:** Emmanuel Ariyo (Ememzyvisuals), works entirely from a phone via
  **Termux** (Android terminal app). No Flutter SDK, no Android SDK, no
  computer — every build, format check, and release happens on **GitHub
  Actions**.
- **What the app is:** "Ekklesia" — an offline-first Christian devotional app
  for DCLM (Deeper Life Campus Fellowship / Deeper Life Bible Church)
  members. Multilingual: English, Yoruba, Hausa, Igbo, Nigerian Pidgin.
  Features: Bible reading (offline, bundled per-language datasets), AI
  Bible assistant (Groq-backed), daily verse/prayer, Impact Academy
  (article-style teaching content with AI-generated quizzes), Sunday
  Service / Bible Study / Global Crusade / Programs sermon library
  (YouTube-backed), DCLM Radio (live Icecast/Airtime streams), offline
  games (imported .zip, added-by-URL, or the built-in native Bible Quiz
  game), on-device TTS narration of Bible chapters.
- **Package name:** `com.ememzyvisuals.ekklesia`
- **Stack:** Flutter, Riverpod (state), GoRouter (`StatefulShellRoute` for
  the 5-tab persistent bottom nav), Drift (SQLite ORM, local-first data),
  `sherpa_onnx` (on-device TTS for yo/ha/pcm), `flutter_tts` (system TTS for
  English), Groq API (AI chat + summaries), YouTube Data API v3, DCLM's own
  Icecast/Airtime radio streams, `just_audio`/`just_audio_background`.
- **No Firebase, no backend server anywhere.** Fully offline-first by
  design; the only network calls are Groq, YouTube Data API, the TTS model
  download host (Hugging Face), and the DCLM radio stream itself — all
  opt-in/on-demand, never required for the app to open.
- **`android/` and `ios/` folders are NEVER committed to the repo.** They're
  generated fresh by `flutter create .` inside `release.yml` on every single
  release build. This is deliberate (keeps the repo lean, avoids native
  project drift) but means **any native Android/iOS customization must be
  re-applied by a CI script every single build** — this is the single most
  important architectural fact for debugging native build issues. See
  Section 2.

---

## 1. Workflow Pattern (the exact operating procedure)

This is how every single fix in this project has been delivered. Keep doing
it exactly this way.

### 1.1 Getting the current code
The person cannot easily `git pull` and diff cleanly on Termux, so every
session starts with a **fresh clone**:
```bash
git clone --depth 1 https://github.com/Ememzyvisuals/Ekklesia-App.git ekklesia-live
cd ekklesia-live
```
Never assume a previous session's local copy is still accurate — always
re-clone before making changes, since the person may have pushed changes via
Termux directly in between Claude sessions.

### 1.2 Making changes
- Edit files directly in the cloned repo.
- **Always verify before shipping**, every single time, using pure static
  checks (no Flutter SDK is ever available to actually compile):
  - Brace balance: `grep -o '{' file | wc -l` vs `grep -o '}' file | wc -l`
  - For YAML (GitHub Actions files): `python3 -c "import yaml; yaml.safe_load(open('file'))"`
  - For anything with heredocs/multi-line bash inside YAML `run:` blocks:
    extract the exact string GitHub Actions would execute (via
    `yaml.safe_load`, not manual reading) and run it against a realistic
    fixture file to confirm it does what's intended. This caught real bugs
    (see Section 3.2) that manual reading missed.
  - Search for **em-dashes (`—`) in user-facing strings** — the person
    explicitly and repeatedly asked for zero dashes anywhere in the UI
    (error messages, status text, loading text, labels). This is a
    recurring category of bug — new dashes keep slipping in, including from
    Claude's own new code. **Always grep the whole codebase for `—`,
    excluding comment lines, before finishing any response that touches UI
    strings.** Pattern used:
    ```bash
    grep -rn "—" lib/ --include="*.dart" | grep -v "^\S*:[0-9]*:\s*//"
    ```
    Comments using em-dashes are fine; anything inside a `Text(...)`,
    `SnackBar(...)`, exception message, or similar user-visible string is
    not.
  - **Const-correctness check**: a recurring, real bug pattern is wrapping a
    non-const value (usually `AppTheme.xxx(context)`, which needs
    `BuildContext`) inside a `const TextStyle(...)`/`const Icon(...)`/etc.
    This is a hard compile error, not just a lint. After any batch
    find-and-replace involving color/theme values, run a bracket-matched
    scan (not a naive regex) across the whole codebase:
    ```bash
    python3 -c "
    import re, glob
    pattern = re.compile(r'const\s+(TextStyle|Icon|BoxDecoration)\(')
    for path in glob.glob('lib/**/*.dart', recursive=True):
        content = open(path).read()
        for m in pattern.finditer(content):
            start = m.end() - 1
            depth = 0; i = start
            while i < len(content):
                if content[i] == '(': depth += 1
                elif content[i] == ')':
                    depth -= 1
                    if depth == 0: break
                i += 1
            call_body = content[start:i+1]
            if 'AppTheme.' in call_body and '(context)' in call_body:
                print(path, call_body[:100])
    "
    ```
    This exact bug was introduced by Claude's own earlier batch fix and
    caught 6 real instances across the codebase in one pass (Section 3.6).

### 1.3 Delivering changes
- **Never** ask the person to copy-paste code manually. Always:
  1. `zip` only the **changed/added files** (not the whole repo) into
     `/mnt/user-data/outputs/some-descriptive-name.zip`, preserving their
     real relative paths (`lib/features/...`) so unzipping over the repo
     places them correctly.
  2. Call `present_files` on the zip.
  3. Give the exact Termux commands to apply it:
     ```bash
     cd ~/storage/downloads
     unzip -o some-descriptive-name.zip -d Ekklesia-main
     cd Ekklesia-main
     git add -A
     git commit -m "Short, accurate description of the fix"
     git push
     ```
     (The extracted folder is always named `Ekklesia-main` — matches what
     the person has used throughout.)
  4. If a **release build** needs re-triggering (the `release.yml` workflow
     is tag-triggered, not `workflow_dispatch`), also give:
     ```bash
     git tag -d v1.0.0
     git push origin :refs/tags/v1.0.0
     git tag v1.0.0
     git push origin v1.0.0
     ```
  5. If deleting a file is required (rare, but happened for obsolete
     logo/dead-code files), explicitly tell them the exact `rm` command to
     run after unzipping — a zip can't express "delete this file that isn't
     in the zip."
- If a fix is large/spans many files, it's fine to package multiple zips
  across a few messages rather than one giant zip — the person has
  successfully applied 20+ separate patch zips this way across the project.

### 1.4 Reading GitHub Actions logs
The person cannot run `flutter analyze`/`flutter build` locally at all — the
**only** signal on whether code compiles is a GitHub Actions log,
screenshotted and sent by the person after every push. This means:
- Every fix should be as close to "guaranteed correct" as static
  verification allows (Section 1.2), because each round trip costs the
  person a real CI run (several minutes) plus a screenshot-and-explain
  cycle.
- When reading a screenshotted error log: the actual failing line/error is
  usually near the bottom, above `Process completed with exit code 1`.
  `flutter analyze` errors show file:line:col; Gradle errors show a `* What
  went wrong` section.
- **Never assume a fix worked without confirmation** — always ask for or
  wait for the next log/screenshot before declaring something resolved.

### 1.5 Honesty conventions established in this project
- When a fix can't be verified (no Flutter SDK/Android SDK available to
  actually compile+run), **say so explicitly** and flag which specific
  fix is lowest-confidence, so the person knows what to test most
  carefully. Example: the sherpa_onnx isolate-offload fix for on-device TTS
  (Section 4) was explicitly flagged as unverified/highest-risk when
  shipped.
- When a hypothesis turns out wrong (e.g., "missing INTERNET permission"
  was first suspected, then research showed `flutter create` includes it
  by default), **say so plainly** rather than quietly dropping the theory.
  The eventual real fix (Section 3.9) was still to defensively guarantee
  the permission in CI, because later diagnostic evidence (Section 3.10)
  strongly re-confirmed a missing-permission signature.
- Own mistakes directly. Several bugs in this log were introduced by
  Claude's own earlier fixes (const-context bug, YAML indentation bug,
  network diagnostics testing methodology bugs) — each is documented here
  exactly as what it was: a real bug Claude introduced and then fixed,
  not glossed over.

---

## 2. Critical Architecture Facts for Debugging Native Build Issues

Because `android/` is never committed and is regenerated by `flutter create
.` on every release build, **all native Android customization lives inside
`.github/workflows/release.yml` as CI steps that patch the freshly generated
files.** Current patches applied, in order, after `flutter create .`:

1. **Ensure INTERNET permission** — checks `AndroidManifest.xml` for
   `android.permission.INTERNET`; adds it via a Python script if missing.
   (Section 3.9/3.10 — evidence-driven, not yet 100% confirmed as the exact
   root cause, but defensively guaranteed either way.)
2. **Bump compileSdk to 36** — via a root-level `subprojects {
   afterEvaluate { ... } }` block in `android/build.gradle.kts`, **prepended**
   (not appended) to the file — this ordering matters, see Section 3.4.
3. **Enable core library desugaring** — required by
   `flutter_local_notifications`.
4. **Patch flutter_inappwebview_android's proguard config** — a transitive
   dependency (via `youtube_player_flutter`) ships a proguard file
   incompatible with current AGP; patched directly in the pub cache.
5. **Configure Android release signing** — injects a real
   `signingConfigs { release { ... } }` block reading from
   `android/key.properties`, built from 4 GitHub secrets
   (`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
   `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`). Handles both Groovy
   (`build.gradle`) and Kotlin DSL (`build.gradle.kts`) — current Flutter
   defaults to Kotlin DSL.
6. **Generate app icons** (`flutter_launcher_icons`) and **splash screen**
   (`flutter_native_splash`) — configured in `pubspec.yaml`, using the real
   supplied Ekklesia logo (`assets/branding/ekklesia_logo_icon_source.png`
   for the icon source, `assets/branding/ekklesia_logo.png` bundled at
   runtime for in-app use).

**Rule for any future native Android issue:** the fix almost always belongs
in `release.yml` as a new "verify and patch a freshly generated file" step,
matching the exact pattern of the 6 above — not as a committed native file
edit, which would just get overwritten on the next `flutter create .`.

**Testing pattern for `release.yml` changes**, established after two real
bugs (Sections 3.2, 3.4) shipped from *not* doing this: never trust manual
reading of a YAML `run:` block. Always extract the actual script via
`yaml.safe_load()` and execute it against a realistic fixture file mimicking
what `flutter create .` really generates, before shipping.

---

## 3. Full Chronological Issue Log

### 3.1 CI pipeline bootstrapping (early session)
- **`pubspec.lock` never committed** → `dependency_check.yml`'s "verify lock
  is in sync" step was silently a no-op (`git diff` on an untracked file
  always reports no changes). Fixed to fail loudly with a clear message if
  the lockfile isn't committed. Added a `generate_lockfile.yml`
  (`workflow_dispatch`) so the lockfile can be generated on a GitHub runner
  since there's no local Flutter SDK.
- **Dead Firebase steps in `release.yml`** — the app has zero Firebase
  dependency (confirmed: no `firebase_core` in `pubspec.yaml`, no
  `Firebase.initializeApp()` anywhere), but `release.yml` was still writing
  `google-services.json` and patching Gradle to apply the Google Services
  plugin. Removed entirely.
- **`flutter analyze` never actually ran before** (blocked earlier by the
  above) — first real run surfaced **13 genuinely pre-existing bugs**
  unrelated to any of Claude's changes: wrong Drift-generated class name
  (`MessageData` → `Message`), `BibleVerse.text` → should've been
  `.content`, missing `uiLocalNotificationDateInterpretation` arg for
  `flutter_local_notifications`, a dead unused field, two missing imports,
  `AvatarService.catalog` accessed as instance member when it's `static`,
  and two undeclared asset directories. All fixed.
- **`auto_format_fix.yml` had no safety check** — `dart fix --apply` +
  `dart format` committed and pushed straight to `main` with zero
  verification. It once broke a valid `final x = Something();` field into
  invalid `const x = Something();` (a known `dart fix` unsafety on this
  project's analyzer version) — twice in a row. Real fix: moved the field
  off the trigger pattern (`late final`, assigned in `initState`) **and**
  added a `flutter analyze --fatal-infos --fatal-warnings` step to
  `auto_format_fix.yml` right before the commit/push step, so a bad
  auto-fix now just fails the job instead of landing on `main`.

### 3.2 Release build: signing config Kotlin DSL bug (real bug, Claude's)
`build.gradle.kts` uses Kotlin DSL by default on current Flutter, but the
original signing-config patch script injected **Groovy** syntax
unconditionally. Failed with "Expecting an element." Fixed by branching the
injected syntax on file extension (`.kts` vs `.gradle`), verified against a
realistic fixture before shipping.

### 3.3 Release build: proguard incompatibility (real bug, upstream)
`flutter_inappwebview_android` (pulled in transitively via
`youtube_player_flutter`) calls `getDefaultProguardFile('proguard-android.txt')`,
which current AGP/R8 rejects outright. Not this project's bug — patched
directly in the pub cache via a `sed` step in `release.yml`.

### 3.4 Release build: compileSdk override + afterEvaluate ordering (two real bugs, Claude's, in sequence)
1. First attempt: appended a second `android { compileSdk = 36 }` block to
   `build.gradle.kts` — didn't work; the actual failing subproject
   (`:file_picker`, not `:app`) has its **own** separate compileSdk
   declaration in its own pub-cache'd `build.gradle`, which app-level edits
   can never touch.
2. Correct fix: a root-level `subprojects { afterEvaluate { ... } }` block
   that forces compileSdk on **every** subproject, including plugin
   modules. But the first version of this **appended** the block to the end
   of the file — crashed with "Cannot run Project.afterEvaluate(Action)
   when the project is already evaluated," because the file already had
   `subprojects { project.evaluationDependsOn(":app") }`, and that call
   forces early evaluation. Fixed by **prepending** the new block instead
   (before any other statement can force early evaluation) — order in the
   file is semantically significant for Gradle Kotlin DSL scripts.

### 3.5 Release build: core library desugaring (real bug, upstream)
`flutter_local_notifications` uses `java.time` APIs requiring core library
desugaring, not enabled by default. Fixed by appending
`compileOptions { isCoreLibraryDesugaringEnabled = true }` +
`dependencies { coreLibraryDesugaring(...) }` — reopening `android {}` and
`dependencies {}` blocks additively is legal in both Gradle DSLs (verified
against fixtures).

### 3.6 Systemic dark-mode bug (real bug, pre-existing + Claude's own regression)
`AppColors.surface`/`.textPrimary`/`.textSecondary` are **hardcoded
light-only constants**; `AppTheme.surface(context)`/etc. are the correct
theme-aware versions. Found and fixed across **9 files**: Home category
tiles + Today's Verse/Prayer cards, Bible screen (including the language
dropdown — same root cause as a separately reported "white background makes
dropdown text invisible in dark mode" bug), AI chat bubbles, Impact Academy
list, quiz screen, bookmarks, downloads, notifications, search.

**A batch sed-based fix for this later introduced 6 real compile errors**
(`const TextStyle(color: AppTheme.textSecondary(context), ...)` — const
wrapping a non-const context-dependent call). Found via the bracket-matched
scan in Section 1.2 and fixed. This is the canonical example of why that
scan step now exists.

### 3.7 Navigation architecture: no shared bottom nav (real bug, pre-existing)
Only `HomeScreen` had a hand-built `NavigationBar` in its own `Scaffold`;
every other screen (Bible, Settings, AI, Games) was an independent
top-level `GoRoute` with **no nav bar at all**. Leaving Home meant getting
stranded with no way back except force-closing the app (compounded by
`context.go()` replacing the nav stack rather than pushing). Fixed by
rebuilding the router around `StatefulShellRoute.indexedStack` with one
persistent `NavigationBar` shared across 5 tabs (Home, Bible, **Games**
— added as a real tab, previously only reachable via Settings, per
explicit request — AI, Settings), in a new `AppShell` widget
(`lib/core/config/app_shell.dart`).

Follow-on bug: the first version of `app_shell.dart` used
`StatefulNavigationShell` (a `go_router` type) without importing
`go_router` — real compile error, fixed immediately.

Also added: a persistent **DCLM Radio mini-player** (`radio_mini_player.dart`)
shown above the bottom nav on every tab once playback starts (play/pause/stop,
tap to open full Live screen) — addresses "radio needs its own navigation
so I don't have to go back to the Live tab to pause it."

Also added: explicit "back to Home" button on the Live screen (uses
`context.go('/home')`, not `pop()`, since Live can be reached from any tab
via the mini-player) and explicit "back to Games" button + `PopScope` guard
on the game WebView screen (Android back gesture can get captured by a
game's own in-page JS/history instead of exiting the screen without this).

### 3.8 Multi-language support: three separate real bugs
1. **`VerseWorker.getTodaysVerse()` hardcoded `language: 'en'`** when
   fetching passage text, ignoring the actual requested language entirely
   (doc comment even said "(English)"). Fixed to use the real language via
   `kAppLanguageToBibleCode`.
2. **`PrayerWorker`'s `language` parameter was accepted but never used** in
   the Groq prompt — always generated English regardless of selection.
   Fixed to translate the system prompt's target language. Also fixed the
   prayer cache key to include language (was date-only, so switching
   language mid-day still served the previous language's cached text).
   **Fallback templates** (used when Groq fails) were a single hardcoded
   English string — this is very likely why "the prayer is always the same
   thing" was reported, if Groq was failing consistently (which it was —
   see Section 3.11). Replaced with several templates per language, chosen
   deterministically per day (flagged: Yoruba/Hausa/Igbo translations are
   functional but need native-speaker review).
3. **`bibleLanguageProvider` (Bible screen's own language state) was
   completely disconnected from `languageProvider` (Settings' app-wide
   language)** — two independent Riverpod providers that never synced.
   Changing language in Settings did nothing to the Bible screen. Fixed:
   `bibleLanguageProvider`'s default now derives from `languageProvider`
   (still overridable per-session via the Bible screen's own dropdown).

**Known unfixed edge case:** `parseBibleReference()` only recognizes
**English** book names. Bookmarking or searching a verse while reading in
Yoruba/Hausa/Igbo/Pidgin stores the reference using that language's own book
name, which will fail to parse when jumping back to it later. Not yet fixed
— flagged as a real, distinct follow-up.

### 3.9 Critical crash: Flutter Material framework doesn't support yo/ha/ig/pcm locales (real bug, confirmed via research)
Forcing `MaterialApp.router`'s `locale:` directly to `Locale('yo')` /
`Locale('ig')` / etc. left Flutter's own framework-level localization
delegates (`GlobalMaterialLocalizations`, `GlobalCupertinoLocalizations`,
`GlobalWidgetsLocalizations`) unable to resolve anything — those three
languages are not among the ~80 languages Flutter ships built-in
translations for (confirmed via Flutter's own tracked issues). The app's
own custom `AppLocalizations` (generated from `lib/l10n/*.arb`, which
**does** cover all 5 languages) kept working fine, but Material-internal
widgets (tooltips, semantics used by `NavigationBar`, etc.) broke — visible
on a real device as: header text renders correctly in Igbo, but the bottom
nav area collapses into a blank/gray box.

**Fix:** three thin custom `LocalizationsDelegate` wrapper classes
(`_FallbackMaterialLocalizationsDelegate`, `_FallbackCupertinoLocalizationsDelegate`,
`_FallbackWidgetsLocalizationsDelegate` in `main.dart`) that report
`isSupported()` as always true, but internally load the real Flutter
translations only for genuinely-supported locales, falling back to English
for yo/ha/ig/pcm. This means a few framework-only strings (default dialog
button labels, etc.) show in English for those 4 languages — an
acknowledged, minor, honest degradation — while every one of the app's own
translated strings keeps working exactly as before.

**Status: shipped, not yet re-confirmed fixed on a real device** (last
report was "not sure if this build has that fix yet" — needs a fresh
Igbo/Yoruba test with a build that definitely includes this commit).

### 3.10 Network diagnostics tool + persistent offline indicator (built), then partially reverted per request
Built `lib/core/services/network_diagnostics.dart` +
`lib/features/settings/presentation/network_diagnostics_screen.dart`
(Settings → Network Diagnostics) — runs real, individual checks against
every actual network dependency (raw DNS+socket to google.com, Groq key
presence, Groq API, YouTube Data API, TTS model host, DCLM radio stream),
showing exact raw results/errors. Also built a small always-visible
"offline" banner (`ConnectivityMonitor` + `OfflineIndicator`) — **this was
later explicitly removed per request** (it changed the visible layout at
the top of every screen; the diagnostics screen itself was kept). Both
`connectivity_monitor.dart` and `offline_indicator.dart` files were
**deleted entirely** (not just unwired) since they had no other consumer —
if either filename appears in a status check as "not found," that is
correct/expected, not a bug.

**Two real bugs in the diagnostics tool itself, found from real usage,
both fixed:**
1. The Groq API check never sent an `Authorization` header — guaranteed a
   false HTTP 401 regardless of whether the person's actual key was valid.
   Fixed to send the real configured key.
2. The DCLM radio stream check used `http.get()`, which waits for the full
   response body — but a live radio stream is a **continuous, infinite**
   body by design, so this check was mathematically guaranteed to time out
   after exactly the configured duration regardless of whether the stream
   was actually healthy. It gave zero real signal, ever. Fixed to use
   `http.Client().send()` and read only the response headers/status,
   explicitly never draining the (endless) body stream.

### 3.11 Deprecated Groq models (real bug, confirmed via Groq's own announcement)
`AppConfig.groqPreferredModel`/`.groqFallbackModel` were hardcoded to
`llama-3.3-70b-versatile` and `llama-3.1-8b-instant` — **both officially
deprecated by Groq on June 17, 2026**, confirmed directly against Groq's own
deprecations documentation. Every Groq call (chat, Impact Academy
summaries/quizzes, prayer generation) was very likely hitting
`model_decommissioned` since that date. This is almost certainly the actual
root cause behind "AI Assistant: something went wrong sending that
message," "Impact Academy: raw SocketException dump," and the "prayer is
always the same" symptom (since it kept hitting the fallback path).

**Fix:** updated to Groq's own recommended replacements —
`openai/gpt-oss-120b` and `openai/gpt-oss-20b` — confirmed as real,
currently-listed model IDs via Groq's own docs.

**Compounding bug, also fixed:** `AIConfig.instance.verify()` (which picks
the actual live model to use) only ever ran **once, at app startup** —
adding or changing the Groq key in Settings never triggered it again. So
even after fixing the model IDs, someone who already has the app installed
and adds/changes their key needed an app restart to pick up a working
model. Fixed: Settings' key-save handler now calls
`AIConfig.instance.verify()` immediately after saving.

**Status: shipped, not yet confirmed fixed on a real device.** This is the
single most likely explanation for most of the AI/prayer/quiz-generation
symptoms reported — re-test this first.

### 3.12 Raw exception text shown directly in the UI (recurring bug pattern, multiple real instances)
A pattern of `_error = e.toString()` or `Text('Error: $e')` surfacing raw
`SocketException`/`ClientException` text (including literal API URLs)
directly in the UI, instead of a friendly message. Fixed **piecemeal
across many sessions** as instances were found — **do not assume this
pattern is fully eliminated**; a fresh exhaustive grep is worth running
periodically:
```bash
grep -rn "Error: \$e\|_error = e.toString()\|content: Text('Error\|Text(e.toString())" lib/ --include="*.dart"
```
Confirmed-fixed locations so far: AI Assistant screen (main send path +
Listen/TTS path), Live screen, Bible screen (chapter-open path +
reference-jump path, the latter now shows `BibleReferenceException.message`
cleanly instead of the raw `toString()` with type prefix), Impact Academy
(`learn_screen.dart`, both the content-load path and the "Generate Summary
+ Quiz" button — the latter now categorizes by error content: offline,
model unavailable, key rejected, or generic).

### 3.13 Bible reading UI redesign
Original chapter view was plain, unstyled text. Redesigned to match a
reference screenshot the person supplied (a polished commercial Bible app):
large centered chapter number, small-caps book name header, superscript-style
verse numbers (small font size directly preceding larger body text, no
manual baseline offset needed), generous line height, a "next chapter" pill
at the end of the list to keep reading forward, and a compact headphone
icon in place of the old full-width "Listen" button.

**Also added: verse-jump-with-blink navigation.** Tapping a search result
or bookmark now opens `BibleScreen(initialReference: ..., initialLanguage: ...)`
directly (via a fresh `Navigator.push`, deliberately bypassing the
shell-tab `/bible` route, since navigating a `StatefulShellRoute` branch's
root doesn't reliably create a new widget instance with new params if that
branch was already visited), scrolls to the exact verse via
`Scrollable.ensureVisible` with a `GlobalKey` per verse, and blinks it gold
3 times via a `Timer.periodic` toggle.

### 3.14 AI conversation history (new feature)
Added a `Drawer` (left-side menu icon appears automatically once a
`Scaffold.drawer` is set — this is why it's on the left, matching the
explicit request) listing every past conversation session grouped by
`sessionId`, each showing a preview (first user message) and relative date
("Today"/"Yesterday"/"3 days ago"), plus "New Chat". `_sessionId` was
changed from `late final` (fixed for the screen's lifetime, one per
calendar day) to mutable, with `_loadHistory()` now clearing and reloading
on session switch, and a `_initialMessageHandled` guard so the
auto-send-prayer-from-Home feature (below) can never re-fire on a session
switch.

**Also added:** tapping "Today's Prayer" on Home now navigates to AI **and**
auto-sends that exact prayer text immediately (was: bare navigation, prayer
text nowhere to be found, person had to manually retype it) — passed via
GoRouter's `extra` parameter through to `AiAssistantScreen(initialMessage: ...)`.

### 3.15 On-device TTS: two real bugs, one confirmed-fixed, one flagged low-confidence
1. **English (`SystemTtsEngine`, wraps `flutter_tts`)**: `synthesizeToFile()`'s
   Future only completes via a native platform completion callback,
   documented across `flutter_tts`'s own issue tracker as simply never
   firing on a meaningful number of Android OEM TTS engines. No timeout
   existed at all — confirmed hang on a real device tapping "Listen."
   Fixed: 45s timeout + a real `SystemTtsTimeoutException` with a friendly
   error, instead of an infinite spinner.
2. **Yoruba/Hausa/Pidgin (`LocalTtsEngine`, wraps `sherpa_onnx`)**: found
   while investigating #1 — `tts.generate(...)` is a **synchronous,
   CPU-bound native FFI call**, run on the main isolate. This doesn't just
   risk hanging; it **freezes the entire UI** (no touches, no rendering)
   for the full duration of ONNX inference, which for a full chapter on
   real low-end Android hardware can be many real seconds. A `.timeout()`
   wrapper cannot fix this (a blocking synchronous call prevents the
   isolate's own event loop, including timers, from running at all until
   it returns). Fixed by moving the whole load+generate+free sequence into
   a spawned isolate via `compute()`, with a self-contained top-level
   function (can't pass the native-pointer-holding `OfflineTts` object
   across isolates, so it's loaded fresh inside the spawned isolate each
   call). The old "keep one model loaded across calls" caching fields
   (`_tts`, `_loadedLanguage`, `_ensureLoaded()`, `unload()`) became fully
   dead code under this design and were removed (would have failed CI's
   `unused_element`/`unused_field` lints otherwise).

**Explicitly flagged when shipped: the isolate-offload fix (#2) is the
lowest-confidence fix of that whole batch** — could not be compiled/run to
verify, unlike the timeout-based fixes which are simple enough to reason
about with high confidence.

**Status per the most recent screenshots: BOTH still show "Could not
generate audio right now. Please try again."** for English AND Yoruba —
i.e., **this is still broken, not yet root-caused after the above fixes**.
Given Section 3.11's Groq model fix was shipped around the same time and
TTS generation is a **separate system from Groq** (on-device, no Groq
involvement) — this specific symptom needs fresh, dedicated
investigation. Worth checking first: whether the friendly error is masking
a *new*, different failure than the ones already fixed (i.e., the 45s
timeout / isolate fix might both be working exactly as designed, correctly
catching a **different** underlying failure that hasn't been diagnosed yet
— e.g., a genuinely missing/corrupted downloaded model file for Yoruba, or
a `flutter_tts` initialization problem specific to the test device's
installed TTS engines for English). **This is a top-priority open item.**

### 3.16 DCLM Radio hang (partially addressed, status unclear)
Earlier fix: added 12s timeouts to `RadioService.playLanguage()`'s
`setAudioSource`/`play()` calls (previously unguarded, matching the same
"unbounded native call can hang forever" pattern as Section 3.15). **Most
recent report ("radio is not working at all, it just keeps running,
running") suggests this may still be unresolved**, though it's also
possible the diagnostic confusion in Section 3.10 (the radio stream test
that was structurally guaranteed to time out regardless of real health) was
muddying the picture. **Needs a fresh test now that the diagnostic tool
itself is fixed** — run Network Diagnostics again and check specifically
whether "DCLM radio stream host" now reports a real, meaningful result
before assuming the in-app player itself is still broken.

### 3.17 Bible Quiz game + URL-based games (new features, built)
- **Bible Quiz**: fully native Flutter mini-game (no WebView, always works
  offline) — `lib/features/games/domain/bible_quiz_data.dart` (15 curated
  KJV verses with blanked key words) + `bible_quiz_game_screen.dart`
  (tap-to-fill word bank mechanic — the reference screenshot's own UI label
  said "Tap or Drag," so tap-only satisfies that spec without needing a
  drag-and-drop library), 8-question rounds, real running score, results
  screen with "Play Again." Reachable from **both** Home's category grid
  (6th tile) and a permanent featured card at the top of the Games tab.
- **URL-based games restored**: Games tab's `+` button is now a
  `PopupMenuButton` with two options — "Import a game (.zip)" (existing,
  offline) and "Add game by link" (new — a dialog collecting a name + URL,
  validated as http/https, stored in a new `UserAddedGames` Drift table,
  played via the same in-app WebView catalog entries already use). New
  `GameEntry.isUserAdded` bool field distinguishes these from zip-imported
  `LocalGames` for correct long-press-to-delete routing.
- Drift schema bumped to v3 (added `UserAddedGames` table, additive-only
  migration, matching the same pattern as the v1→v2 `LocalGames` addition).

### 3.18 Ekklesia companion character system + real logo (new feature, built)
Person supplied a real AI-generated logo (green/gold, cross + open Bible +
dove, "EKKLESIA" wordmark) and 4 character illustrations of the same
recurring figure in different poses, with a detailed integration spec.
Built:
- Processed/cropped/optimized all 5 images (Pillow: tight-cropped
  transparent backgrounds, resized to reasonable in-app sizes — originals
  were 1-2MB+ each, now ~100-250KB).
- `lib/core/widgets/ekklesia_companion.dart` — one reusable
  `EkklesiaCompanion` widget with 4 semantic types (`welcome`, `bible`,
  `prayer`, `ai`), mapped to the 4 character images **by their actual pose**
  (standing/waving/holding-Bible → welcome; seated-with-laptop-and-prompt-bubbles
  → ai; kneeling-praying → prayer, also reused as the general
  empty/error-state companion per explicit clarification; seated-reading →
  bible), with accessibility semantics (localized labels added to all 5
  ARB files — flagged as functional-but-needing-native-review for
  yo/ha/ig, same caveat as the prayer fallback templates), an optional
  subtle floating animation, and an `isDecorative` flag for contexts where
  adjacent text already conveys the same meaning.
- Wired in: Home screen's greeting row (Welcome, small/subtle), AI
  Assistant's empty/new-chat state (AI companion + suggestion chips
  mirroring the character art's own speech bubbles), Bible screen's
  auto-import loading state (Bible companion), Sermon Library's
  empty/error state (Prayer companion, per the "general empty/error state"
  mapping).
- Real logo wired into `flutter_launcher_icons`/`flutter_native_splash`
  config (replacing an earlier Claude-designed placeholder SVG logo, which
  was fully removed — deleted files, not just unwired, per "do not invent
  another logo").
- **Deliberately not done, by design choice, not oversight:** a character
  on every single screen (spec explicitly said not to — "clean, peaceful,"
  no overcrowding) and a character directly inside the compact Today's
  Verse/Prayer cards (would visually compete in an already-tight layout).

### 3.19 Bible import UX (real bug/UX gap, fixed)
The Bible dataset for every language is **already fully bundled inside the
app** (`assets/bible/*.json`, several MB each) — "importing" just means
parsing that bundled JSON once into the local SQLite DB, purely local, no
network. The original UI required an explicit "tap to import" button/gate
before showing any content — unnecessary friction for a one-time, fully
local, unavoidable setup step. Fixed: replaced with a `_AutoImportingView`
that triggers the import automatically and silently on first open of a
language, showing just a brief "Setting up your Bible" spinner (now with
the Bible companion illustration), never a button.

### 3.20 Groq Markdown rendering, TTS/Radio/YouTube hangs, games not appearing, font size (real bugs, fixed)
Fixed as one batch, from a fresh device screenshot session plus a
downloaded copy of the actual repo. **Section 3.16's status is now
resolved, not just re-tested** — the timeout genuinely was still missing
in the checked-out code.

- **Groq Markdown shown raw everywhere** (`**bold**`, `- ` lists, `#`
  headers, `| |` tables all visible as literal characters in the AI
  Assistant chat, Impact Academy summaries, sermon "AI overview," and the
  Home prayer preview card). Built `lib/core/widgets/markdown_text.dart`
  — a small hand-written renderer (headers, bold/italic/inline code,
  bullet/numbered lists, pipe tables), deliberately not a pub.dev package
  like `flutter_markdown` given there's no local Flutter SDK here to
  verify an unfamiliar package's API against. Wired into every
  Groq-output display site found; a `stripMarkdown()` helper handles
  spots needing a single-line/`maxLines`-truncated preview instead (the
  Home prayer card, the sermon overview's topic/points), since a
  block-widget renderer has no single `maxLines` to truncate against.
- **English TTS "Could not generate audio," very frequently** — real,
  confirmed bug in `system_tts_engine.dart`: `synthesizeToFile(text,
  fileName)` was missing `isFullPath: true`. flutter_tts's documented
  behavior (matches an open upstream issue with the identical symptom):
  without that flag, Android writes the file to the plugin's *own*
  internal directory regardless of what "fileName" looks like, while this
  code was checking for the result in a totally different
  path_provider-chosen directory — so the exists() check failed almost
  every time even when synthesis genuinely worked. Fixed by passing the
  exact same path to both the plugin call and the check.
- **TTS model download → immediate "could not generate" after
  downloading** — `TtsModelRegistry` marked a model "ready" once a file
  existed with non-zero length, which a partial/interrupted download also
  satisfies. Fixed: downloads now go to `.part` files, renamed to their
  real names only on full success; a failed download also cleans up any
  leftover `.part` file so a retry starts clean.
- **DCLM Radio endless spinner** — confirmed via screenshot: `Tap to Play`
  spinning forever, never erroring. `RadioService.playLanguage()` had
  **no timeout at all** on `setAudioSource()`/`play()` in the actual
  checked-out code, despite 3.16 believing this was already fixed —
  either lost or never actually landed. Added 15s timeouts back.
- **YouTube not syncing** — `youtube_repository.dart`'s `http.get()` calls
  also had no timeout. Network Diagnostics screenshot showed a genuine
  10s hang against `googleapis.com` specifically while every other host
  (Groq, the TTS model host, the DCLM stream, even plain `google.com`
  DNS) answered fine — a pattern consistent with that one host being
  blocked/throttled by the network or carrier, which isn't fixable
  client-side. Added a 20s timeout plus an honest, distinguishing message
  ("YouTube could not be reached — this can happen if it's blocked on the
  current network") instead of hanging silently forever.
- **"Add game by link" silently does nothing** — real, high-confidence
  root cause found in `app_database.dart`'s Drift migration: `onUpgrade`
  only checked `if (from < 3)` before creating the `UserAddedGames`
  table. If any earlier build's `schemaVersion` and its actually-shipped
  tables ever drifted out of sync on a real device (an entirely plausible
  history across this many iterations), Drift has no way to notice —
  it only re-runs migrations when the stored version is strictly less
  than current, never by checking what tables actually exist. Every
  insert would then fail with a real "no such table" error that nothing
  was catching in the "Add game by link" dialog specifically (the .zip
  import path already had proper error handling; the link path didn't).
  Fixed both: migration now also verifies the table is actually present
  via `sqlite_master` before trusting the version number, and the dialog
  now shows a real error message instead of failing silently.
- **Font size setting** — added a persisted `fontScaleProvider`
  (`app_settings_service.dart`, same `StateNotifierProvider` pattern as
  theme/language) applied app-wide via `MaterialApp.router`'s `builder`
  in `main.dart`. **Important gotcha found along the way**: the Bible
  reader's verse text uses a raw `RichText`, which — unlike `Text` —
  does NOT automatically pick up ambient `MediaQuery` text scaling; it
  needed `textScaler: MediaQuery.textScalerOf(context)` passed explicitly
  or the whole feature would have silently done nothing on the one
  screen it was actually requested for. Control surfaced as an "Aa"
  button on the Bible screen's app bar (a slider, 85%–160%) plus a
  matching entry in Settings.
- **Not yet done / worth flagging**: no compiler was available anywhere
  in this session (same constraint as every prior entry) — all of the
  above was verified by careful reading, brace/paren balance checks, and
  cross-referencing flutter_tts's/Drift's actual documented behavior, not
  by building. Test on a real device before considering these closed,
  same as every other entry in this log.

---

### 3.21 3.20's TTS/Radio/YouTube fixes did NOT resolve the reported symptoms — real games bug found, TTS/Radio/YouTube now instrumented instead of guessed at again
Fresh screenshots after 3.20 shipped: TTS still "Could not generate audio
right now" for **both** English and Yoruba (not the new, more specific
messages 3.20's fixes should have produced), Radio still "Couldn't start
the stream," YouTube still the old generic message, and — critically —
added games (both by-link and by-.zip) still invisible even though the
"Added ..." toast confirmed the insert genuinely succeeded this time.

**Games — real root cause found, high confidence, different from 3.20's
theory.** Since the insert demonstrably succeeded (no error toast, no
silent failure), the earlier "missing database table" theory in 3.20 was
not what's actually happening here. The real bug: `_GameGrid`'s
`GridView.builder` in `games_screen.dart` has no `shrinkWrap`/`physics`
override, and sits directly inside the screen's outer `ListView` —
a well-known Flutter layout conflict (nesting one scrollable inside
another's unbounded-height context). In debug mode this normally throws
a visible red-screen layout exception; in a release build it can instead
just silently occupy zero height. This explains why the grid area has
been blank in literally every Games screenshot across this whole
project, added game or not — the bundled catalog would have hit the
exact same invisible failure if it ever had entries. Fixed: added
`shrinkWrap: true, physics: const NeverScrollableScrollPhysics()`.
3.20's database self-heal fix is left in place as harmless
defense-in-depth, but should not be treated as the fix that mattered
here.

**TTS/Radio/YouTube — not re-fixed blind a third time. Instrumented
instead.** Two guesses (3.15/3.16's original timeout fixes, then 3.20's
follow-up) have now both failed to resolve what's actually happening on
the device, which means guessing a third time without seeing the real
exception text is not a responsible use of anyone's time. Concretely:
English TTS showing the *generic* "Could not generate audio" message
(not 3.20's new, more specific "voice engine did not respond" message)
means the actual failure isn't the `SystemTtsTimeoutException` path 3.20
targeted — it's a different exception being thrown somewhere in
`synthesizeToFile()` that nothing has actually seen the text of yet.
Rather than guess a fourth root cause, this batch adds a **"Details"**
tap target next to every friendly error message that already had a real
exception behind it and was discarding it (`tts_service.dart`'s
`TtsGenerationException.message`, `YoutubeWorker.lastErrorDetail` now
threaded through from `AppFailure.debugDetail` which existed but was
never read, and the raw `e.toString()` on Radio's catch block) —
covering Bible screen TTS, AI Assistant TTS playback, Live screen's
Radio error, and Live screen's YouTube sync error. Tapping "Details"
opens a selectable/copyable dialog with the real text. **Next step is
mechanical, not another investigation**: have the person tap Details on
whichever of these still fails and paste back exactly what it says —
that will finally give a real root cause to work from instead of another
plausible-sounding guess.

---

### 3.22 The real TTS and Radio root causes, from actual device error text (3.21's Details links delivered)
The Details links added in 3.21 worked exactly as intended — real
exception text came back, and none of it matched any of the three prior
guesses (3.15/3.16, 3.20). All three are now fixed from confirmed,
specific evidence:

- **Yoruba/Hausa/Pidgin: `Exception: Please initialize sherpa-onnx
  first`.** Genuine root cause, not a guess: `sherpa_onnx`'s Dart
  bindings require an explicit `initBindings()` call before constructing
  any `OfflineTts`, and nothing in this codebase called it anywhere,
  ever — confirmed by grep across the whole `lib/` tree. Fixed by
  calling it inside `_generateInIsolate` (`local_tts_engine.dart`), not
  once at app startup — dart:ffi bindings are isolate-local, and every
  synthesis call spawns a fresh isolate via `compute()`, so it has to
  happen there specifically.
- **English: `SystemTtsTimeoutException: the device TTS engine did not
  respond`.** flutter_tts requires an explicit
  `awaitSynthCompletion(true)` call before `synthesizeToFile`'s Future
  will ever resolve on completion — a separate opt-in from
  `awaitSpeakCompletion` (which only covers `speak()`), added
  specifically for file synthesis per the package's own changelog.
  Nothing was calling it, so the Future had nothing arming its
  completion signal and was doomed to sit until the 45s timeout fired,
  every single time, regardless of whether the underlying device TTS
  engine was working fine. Fixed in `_ensureConfigured()`
  (`system_tts_engine.dart`).
- **Radio: `LateInitializationError: Field '_audioHandler@...' has not
  been initialized`** (seen once), and separately a genuine
  `TimeoutException` on `setAudioSource()`/`play()` (seen another time —
  these are two different real failure modes, not the same bug twice).
  Root cause of the `LateInitializationError`: `main.dart`'s
  `JustAudioBackground.init()` call had only a 5s timeout, and any
  failure there was silently swallowed with zero record of it —
  `RadioService` then went on to build a MediaItem-tagged `AudioPlayer`
  assuming setup had succeeded when it hadn't. Fixed with a new
  `JustAudioBackgroundInit` helper (`radio_service.dart`): startup's
  timeout bumped to 12s, a `markSucceeded()` flag records whether it
  actually worked, and `playLanguage()` now retries (20s allowance, a
  fair trade once it's blocking one explicit user action rather than
  app startup) before ever building a tagged player — falling back to
  an untagged player (plays fine, just no lock-screen art) if it still
  can't set up, instead of crashing the same way again. The separate
  plain timeout on `setAudioSource()`/`play()` is left as-is (3.20's
  15s timeout) — worth retesting specifically now that the
  `LateInitializationError` path is fixed, since that crash may have
  been masking how often the plain timeout was the actual cause.
- **Not yet addressed, raised rather than assumed**: the person asked
  for a hardcoded/shared Groq API key to be used as a fallback when no
  personal key is set. `groq_service.dart`'s own doc comment states this
  was a deliberate prior decision ("no cloud infrastructure of any kind
  runs for this app, including a shared-key proxy... No fallback, no
  shared quota") — a real security tradeoff (a key baked into a public
  APK is extractable by anyone who decompiles it). Flagged back to the
  person rather than silently reversed; implement only on explicit
  confirmation they understand and want that tradeoff.

---

### 3.23 3.22's TTS/Radio fixes still showing identical error text — likely testing an un-rebuilt APK; Live screen landscape UI break fixed (new, real bug)
Fresh screenshots after 3.22 shipped show the **exact same** error text
as before — same `SystemTtsTimeoutException`, same
`LateInitializationError: Field '_audioHandler@...'` — not new/different
symptoms. This is meaningfully different from 3.20's situation (where
3.21's Details links revealed genuinely different exceptions than 3.20
had targeted, proving 3.20's fixes really didn't address the actual
problem). Here, getting back the literal identical exception text after
two independently-verified, well-evidenced fixes (flutter_tts's
documented `awaitSynthCompletion` requirement; the confirmed
`LateInitializationError` root cause) is much more consistent with **the
new build never actually having been installed** than with both fixes
somehow failing. **Before investigating further, confirm: did the
GitHub Actions build after the batch-3 tag push actually finish
successfully, and was the resulting new APK actually installed (not
just the existing app reopened)?** Don't re-diagnose TTS/Radio from
scratch until that's ruled out — re-verify the build actually shipped
first.

**Real, new, separate bug found and fixed this round regardless**: the
Live screen's embedded YouTube player used a bare `YoutubePlayer(
controller: ...)` with no `YoutubePlayerBuilder` wrapping it — unlike
`video_player_screen.dart`, which already does this correctly. The bare
player still listens for device rotation internally and tries to go
fullscreen on its own, but with nothing wrapping the rest of the
screen's layout (AppBar, DCLM radio section, language picker) in that
same builder, none of it knew to get out of the way on rotation —
confirmed by the person as the whole page breaking into a half-
landscaped mess instead of a clean fullscreen video. Fixed by
restructuring `live_screen.dart`'s `build()` to move the
`StreamBuilder<VideoEntry?>` to the top level and conditionally wrap the
whole `Scaffold` in `YoutubePlayerBuilder` (via a new `_buildScaffold`
helper) whenever there's an active live video/controller, matching
`video_player_screen.dart`'s already-working pattern exactly.

---

### 3.24 The REAL final TTS root cause — a manifest-level Android 11+ requirement, confirmed against Android's own developer docs, executed and verified
The person confirmed 3.22's build genuinely was installed and TTS still
hung identically — 3.23's "probably an un-rebuilt APK" theory was wrong,
and worth recording as wrong rather than quietly dropped: two real,
correct Dart-level fixes (3.22's `awaitSynthCompletion`/`initBindings`)
were both necessary but not sufficient, because the actual remaining
blocker was never in this app's Dart code at all.

**Root cause, confirmed directly against Android's own developer
documentation** (developer.android.com/about/versions/11/behavior-
changes-11), not a StackOverflow guess: apps targeting Android 11+ that
use text-to-speech must declare a `<queries>` element for
`android.intent.action.TTS_SERVICE` in their manifest, or Android's
package-visibility restrictions prevent the app from even seeing an
installed TTS engine — `TextToSpeech` initialization then silently never
completes, no error, no timeout of its own, just permanently stuck. This
explains the exact reported symptom ("just keeps rolling forever") on
both the Bible screen and the AI Assistant's Listen button — they share
the same underlying `SystemTtsEngine`, so a manifest-level gap affects
both identically. This was never addressed anywhere in this codebase
because there IS no committed `android/` directory to check — `flutter
create .` generates it fresh in CI (see 3.x's platform-folder-generation
notes), and Flutter's default template has no way to know this app uses
TTS at all.

Fixed with a new `release.yml` step ("Ensure TTS package-visibility
queries element is present"), same "verify and patch a freshly
generated file" pattern already established for the INTERNET permission
step right above it. **Actually executed against a mock manifest in
this session** (not just read for plausibility) to confirm the Python
patch logic produces valid, correctly-placed XML before shipping it —
given this can only be verified by testing on a real device days later,
that in-session execution is the strongest verification available
without deploying.

---

### 3.25 The REAL Radio (and TTS-playback) root cause — the same class of manifest gap, now confirmed against just_audio_background's own official setup docs
The key clue that broke this open: the identical `LateInitializationError:
Field '_audioHandler@...' has not been initialized` appeared on **both**
RadioService (DCLM Radio) **and** AudioService (Bible/AI Assistant TTS
playback) — two otherwise-unrelated audio paths sharing one failure.
3.22's retry-with-longer-timeout fix treated this as a timing problem
specific to Radio; a shared, identical, permanent (not intermittent)
failure across two different features pointed somewhere more
fundamental instead.

**Root cause, confirmed directly against `just_audio_background`'s own
official pub.dev setup instructions**, not inferred: the package
requires two manifest-level changes this project never had a mechanism
to apply, since (as with 3.24's TTS fix) `android/` is generated fresh
by `flutter create .` every build and nothing patched it for this
specifically:
1. `WAKE_LOCK`, `FOREGROUND_SERVICE`, and
   `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permissions.
2. **The actually critical part**: the manifest's launcher `<activity>`
   must be `com.ryanheise.audioservice.AudioServiceActivity`, not
   Flutter's default `.MainActivity`. Without that specific activity
   class, the native Android side never wires up the audio handler
   `just_audio_background` depends on **at all** — a permanent gap, not
   a slow one, which matches "identical failure every single time" far
   better than any timeout theory. This project has no custom native
   Android code (no committed `android/` directory, nothing else in the
   workflow touches `MainActivity`), so replacing it outright with the
   package-provided activity is safe — `AudioServiceActivity` is itself
   a `FlutterActivity` subclass built specifically as a drop-in
   replacement for this exact purpose.

Fixed with a new `release.yml` step ("Configure manifest for
just_audio_background"), same pattern as 3.24's TTS queries step.
**Actually executed against a realistic, fully-detailed mock
Flutter-generated manifest in this session** (not just read for
plausibility) — confirmed both the permissions and the activity-class
swap land correctly. Then went further: extracted the *exact* Python
code embedded in the real, saved `release.yml` file (not a hand-retyped
copy) and ran it through `compile()` to confirm the file that will
actually execute in CI is syntactically valid, not just a similar-
looking draft.

3.22's Dart-side `JustAudioBackgroundInit` retry-and-fallback logic
(`radio_service.dart`) is left in place — harmless, and still a
reasonable defense against a *genuinely* slow (rather than structurally
broken) init on some device.

---

### 3.26 Added a visible build tag — stop guessing about "did you rebuild" entirely
3.25's fix still came back with the **literal identical**
`LateInitializationError` text (same object hash, `@1072018634`, both
times) after the person explicitly confirmed they'd rebuilt and
reinstalled. Several rounds now have hinged on "is this genuinely the
same bug, or an old APK" with no fast way to know for certain — that
ambiguity itself is now the biggest blocker to real progress, worse
than any individual bug.

Added `AppConfig.buildTag` (a plain string, bump it every batch —
currently `'batch6-2026-08-25'`), surfaced in two places: a "Build" row
in Settings, and appended automatically to every "Error details" dialog
across the app (Bible screen, AI Assistant, Live screen's Radio and
YouTube errors). **Going forward: before diagnosing any bug report,
check that the build tag in the screenshot/Settings matches what was
most recently shipped.** If it doesn't, the conversation is "please
rebuild and reinstall," not "let me re-investigate this bug" — no
exceptions, and no more relying on the person's own belief that they
rebuilt (they can genuinely believe it and still be wrong, e.g. an
Actions build that failed silently from their perspective, a stale
browser download, an APK that didn't actually reinstall over the old
one).

Also clarified for the record: the person's report that "YouTube is
broken again, you tampered with it" doesn't match what actually
happened — no batch since 3.21 has touched `youtube_repository.dart` or
`youtube_worker.dart` (their fetch/sync logic). 3.23's landscape fix
only restructured `live_screen.dart`'s widget tree; it didn't change
when or how often syncs happen. A prior screenshot from this same
person showed YouTube correctly rendering a live stream after that
fix. Without Details text for this specific occurrence it's unknown
whether this is a real regression or just "no live stream currently
running" (a normal, correct empty state) — get the Details text before
assuming either way.

---

### 3.27 `just_audio_background` removed entirely — the real fix, after three targeted attempts at configuring it correctly all failed
The build tag (3.26) did its job: the person's next report came back
with `batch6-2026-08-25` visibly present in both Settings and every
error dialog, proving definitively that 3.25's manifest fix — confirmed
present in the actual running build — still did not resolve the
`LateInitializationError`. That rules out "testing an old build" for
good on this issue.

**The tell that broke this open**: this exact same error was now
showing on Radio, TTS generation, AND TTS playback (AI Assistant's
"Listen" and the Bible screen's "Something went wrong generating
audio," both surfacing the identical `_audioHandler` error) — every
single audio feature in the app, not just the one
(`RadioService`/`AudioService`) that explicitly used MediaItem tags.
`AudioService` (`audio_service.dart`, used for TTS playback) has never
imported or used `just_audio_background`/`MediaItem` at all — confirmed
by grep. A bug confined to code that never touches the package cannot
be fixed by configuring that package more correctly; it means calling
`JustAudioBackground.init()` **anywhere** in the app — whether it
succeeds or fails — silently takes over the platform implementation for
**every** `AudioPlayer` created afterward, app-wide, not just ones that
opt into background/MediaItem features. Three independently-researched,
docs-confirmed, in-session-executed fixes (3.22's retry logic, 3.24's
TTS manifest queries, 3.25's `AudioServiceActivity`/permissions swap)
were all real, correct responses to real, documented requirements of
that package — and still insufficient, because the actual fix needed
was never "configure it correctly," it was "don't depend on it."

**Fix**: removed `just_audio_background` from `pubspec.yaml` entirely,
removed the `JustAudioBackground.init()` call from `main.dart`, removed
the `JustAudioBackgroundInit` retry helper and all `MediaItem` tagging
from `radio_service.dart` (now plain `AudioSource.uri()`, no tag), and
— critically, to avoid a *new* build failure — removed 3.25's
`release.yml` step that swapped the manifest's activity to
`com.ryanheise.audioservice.AudioServiceActivity`, since that class no
longer exists on the classpath once `just_audio_background`'s
transitive dependency `audio_service` is gone; leaving that step in
would have broken the build outright (manifest merger failure, unknown
class). Real, acknowledged cost: no lock-screen/notification playback
controls for Radio or TTS anymore. Real benefit: plain `just_audio`
(still used everywhere) needs no equivalent native Android setup and
has had none of these failures across this entire investigation —
every audio feature in the app was broken without this, so reliability
wins here. Bumped `AppConfig.buildTag` to `'batch7-2026-08-25'`.

Also: the person explicitly asked to "delete everything TTS/audio and
rebuild with something that already works" — this is the actual
substance of that request (dropping the fragile, hard-to-configure
package for the simpler one that's been reliable throughout), just
scoped to the specific dependency that was actually causing every
failure rather than a full rewrite of Bible TTS/Radio from zero, which
the evidence didn't point to as necessary — the synthesis-side fixes
(3.22's `awaitSynthCompletion`/`initBindings`, 3.24's TTS manifest
queries) were never in question and remain in place.

---

## 4. Currently Open / Unresolved Issues (in priority order)

0. **Read 3.27 before touching anything below.** Check the build tag
   first (now `batch7-2026-08-25`), every time, before re-diagnosing
   TTS/Radio/YouTube.
1. **TTS + Radio: `just_audio_background` removed entirely (3.27), not
   yet confirmed on a device.** 3.22/3.24/3.25's targeted fixes for that
   package all turned out to be correct-but-insufficient — the real fix
   was dropping the dependency, not configuring it further. If
   `LateInitializationError`/`_audioHandler` shows up again after this,
   that would be genuinely surprising (the package is no longer in
   pubspec.yaml at all) and worth a careful look at whether the
   dependency truly got removed from the built APK, not a new theory
   about the same package. TTS's synthesis-side fixes (3.22/3.24 —
   `awaitSynthCompletion`, `initBindings`, the manifest `<queries>`
   element) are unrelated to this and remain in place; if TTS still
   fails after 3.27, check whether the failure is happening during
   synthesis or during playback specifically (the Details text should
   show which).
2. **Known, accepted regression from 3.27**: no lock-screen/notification
   playback controls for Radio or TTS anymore. Was a real goal earlier
   in this project's history; deliberately traded away for reliability
   after `just_audio_background` proved unworkable across three
   attempts. Worth someday revisiting with a fresh, more careful
   integration if reliability is ever solid enough to justify the risk
   again — not a near-term priority given how much of this project's
   effort has already gone into this one dependency.
3. **YouTube — actually working now**, per the person's own screenshot
   (a live "Monday Bible Study" stream rendering correctly). No longer
   in "broken" status; downgraded from prior open-issue entries.
   Landscape rotation while viewing it was broken (separate UI bug, not
   a YouTube API/sync issue) — fixed in 3.23.
4. **Hardcoded/shared Groq API key fallback — explicitly requested,
   deliberately not implemented (3.22), still awaiting the person's
   explicit confirmation.** This reverses a real, prior security
   decision (`groq_service.dart`'s own doc comment: "no fallback, no
   shared quota," specifically to avoid an extractable key in a public
   APK). Only implement on their explicit confirmation they understand
   and accept that tradeoff.
5. **`parseBibleReference()` only supports English book names** — bookmarks/
   search results saved while reading in Yoruba/Hausa/Igbo/Pidgin will fail
   to parse when jumped back to. Known, not yet fixed.
6. **Igbo/Yoruba locale crash fix (3.9) not yet re-confirmed** on a build
   that definitely includes that commit — last status check was "not sure
   if this build has the fix yet."
7. **Per-verse TTS + synchronized highlight during audio playback** —
   explicitly requested (the person wants the specific verse currently
   being read aloud to highlight in real time, meaning TTS needs to
   generate/play per-verse rather than as one whole-chapter blob) — **not
   started at all.** Blocked on TTS actually working at all first (#1).
8. **Translations needing native-speaker review** (functional, not
   verified for naturalness/accuracy): the 5 companion accessibility
   labels per non-English language, and the prayer fallback templates for
   yo/ha/ig/pcm (3.8).
9. Minor: no drag-and-drop in the Bible Quiz game, tap-only (matches the
   reference screenshot's own "Tap or Drag" label, so treated as
   acceptable, not a bug).
10. Minor: `sermon_library_screen.dart` shows the same YouTube sync error
    as the Live screen but wasn't given a "Details" link in 3.21 (only
    Live screen was) — low priority since the same underlying error is
    already visible with Details on Live.

## 5. Confirmed-Working / Closed Issues (do not re-investigate these)

- CI pipeline: format/fix, analyze, dependency check, security scan, and
  release build all pass end-to-end (as of the last full green run).
- Real signed APK/AAB builds successfully producing installable output.
- Systemic dark-mode bug (3.6) — fixed across all 9 files, verified no
  remaining instances via exhaustive scan.
- Bottom nav / shell navigation (3.7) — fixed, 5 tabs including Games.
- Multi-language Bible/Prayer content (3.8) — fixed at the code level (verse
  and prayer text now genuinely vary by language); the *Igbo/Yoruba locale
  crash* was a **separate, additional** bug (3.9) layered on top, also
  fixed but not yet re-confirmed (see Section 4, item 4).
- Groq model IDs updated to non-deprecated ones (3.11) — **not yet
  confirmed working on a real device**, but the root cause is confirmed
  with high confidence via Groq's own official deprecation announcement.
- Raw-exception-in-UI pattern — fixed in every location found so far
  (3.12), but given how many times new instances have been found, do not
  assume this is fully eliminated without a fresh grep.
- Bible reading UI redesign + verse-jump-with-blink (3.13) — built,
  reasonably confident, not yet re-confirmed visually on latest build.
- AI conversation history + prayer auto-send (3.14) — built, not yet
  confirmed on device.
- Bible Quiz game + URL-based games (3.17) — built, not yet confirmed on
  device.
- Companion character system + real logo (3.18) — built, not yet confirmed
  visually on device.
- Bible auto-import UX (3.19) — fixed, matches "remove that import
  requirement" request directly.
- Network Diagnostics tool itself (3.10) — both known bugs in the tool are
  fixed; the tool's *results* should now be trustworthy for future
  debugging.
- Groq Markdown now rendered properly everywhere it was found being shown
  raw (3.20) — AI Assistant chat, Impact Academy, sermon "AI overview,"
  Home prayer preview. Code-level fix is straightforward and low-risk
  (a self-contained rendering widget, no new dependency); not yet visually
  confirmed on device but low concern relative to the other 3.20 items.
- Font size setting (3.20) — built, including the `RichText`
  ambient-scaling gotcha fix specifically for the Bible reader; not yet
  confirmed on device.

---

## 6. Sensitive Data Handling Note

At one point the person pasted a real base64-encoded Android release
keystore and a real keystore password directly into chat. Both were
treated as **compromised on exposure** — the person was advised to
regenerate a fresh keystore with a new password rather than continue using
the exposed one, and to use their phone's Files app (not terminal
copy/screenshot) to move sensitive values into GitHub Secrets going
forward. If continuing this project, do not ask for or repeat back
keystore contents, API keys, or passwords in chat under any circumstances
— guide the person to paste secrets directly into GitHub's secret input
fields instead.

---

*End of handoff document. Written to be self-contained — a fresh session
with this file plus a current repo checkout should not need to re-derive
any of the above from scratch.*
