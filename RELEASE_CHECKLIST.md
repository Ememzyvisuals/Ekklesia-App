# Release Checklist

Nothing on this list has been checked off yet — this is the checklist
for whoever takes this to an actual store submission, not a record of
completed work.

## Code

- [ ] `flutter analyze` — zero issues
- [ ] `flutter test` — all passing (see `test/README.md` for current
      scope; expand coverage before relying on this as a real gate)
- [ ] `dart format --set-exit-if-changed .` — clean
- [ ] No `TODO`/`FIXME`/placeholder markers (`grep -rniE "TODO|FIXME" lib
      functions/src` should return nothing real — a few legitimate
      `placeholder:` parameter names in image-loading widgets are fine,
      see `FINAL_AUDIT_REPORT.md`'s note on this)
- [ ] `.env` is in `.gitignore` and was never committed (check git
      history, not just the current `.gitignore`)

## Firebase

- [ ] Firestore rules deployed and reviewed (not left in test mode)
- [ ] If deploying `functions/` as a rollback path (optional — see
      `PHASE2_NOTES.md`, not required by default): `GROQ_API_KEY` and
      `YOUTUBE_API_KEY` set in Secret Manager, not anywhere in the
      client bundle; all scheduled functions confirmed running (check
      `firebase functions:log` over at least one full daily cycle);
      billing alerts configured (Blaze plan — Cloud Functions/Scheduler
      have real costs at scale, even within free-tier quotas for most
      apps)
- [ ] If using the default Cloudflare Workers path instead: `GROQ_API_KEY`,
      `YOUTUBE_API_KEY`, and `GOOGLE_SERVICE_ACCOUNT_JSON` set as Worker
      secrets (`wrangler secret put ...`) for all three Workers — see
      each Worker's README.md
- [ ] All three Cron Triggers (`daily-content`) and the `youtube-sync`
      trigger confirmed running (`wrangler tail` over at least one full
      daily cycle — no built-in retries, so a silent failure stays
      silent until you check)

## Store requirements (do these — they're not code changes)

- [ ] Privacy policy published and linked (required by both stores;
      this app collects auth email, reading/usage data — be accurate)
- [ ] App icon designed and applied (currently no real icon asset exists
      — see `DEPLOYMENT_GUIDE.md`)
- [ ] Screenshots for each supported device size
- [ ] Store listing text, in whichever languages you're targeting
- [ ] Age rating questionnaire completed accurately
- [ ] Permissions justification (if any are added later — none required
      as of this pass)

## Localization

- [ ] `test/l10n/arb_parity_test.dart` passing (automated, but confirm)
- [ ] At least a spot-check native-speaker review of Yoruba/Hausa/Igbo
      strings — see `LOCALIZATION_GUIDE.md`'s translation-quality note;
      these have not been verified by a native speaker as of this pass

## Bible engine specifically

- [ ] Spot-check the ~4 chapters per language flagged `approximate` in
      `BIBLE_IMPORT_NOTES.md` — confirm the rendered text and "(approx.
      numbering)" label look reasonable in the actual UI, not just in
      the generated JSON
- [ ] Confirm all 5 languages' `assets/bible/*.json` files are actually
      bundled in the release build (check APK/IPA contents — easy to
      accidentally exclude via a pubspec typo)

## Final

- [ ] Full manual pass through `DEVELOPER_VERIFICATION_GUIDE.md`
- [ ] Tag the release in git and update `CHANGELOG.md` with a real
      version number (this project has no version history yet)
