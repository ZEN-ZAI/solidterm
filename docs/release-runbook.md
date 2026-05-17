# Release runbook

Concrete checklist for cutting a SolidTerm release. Reference source: `vault/research/15-release-engineering.md`.

This doc is the on-call playbook — step-by-step with no interpretation needed. Anything marked `❗` requires human verification.

## Pre-release gate (any release, stable or beta)

- [ ] `main` branch is green in CI (last commit ≥ 24 h old, no in-flight bug reports)
- [ ] Local `cargo test --workspace --all-features` passes
- [ ] Local `xcodebuild test -scheme SolidTerm -destination 'platform=macOS'` passes (once Xcode project lands)
- [ ] Smoke-test on a wiped macOS 14 VM + macOS 15 VM (Tart or UTM) with unsigned debug build
- [ ] ❗ `CHANGELOG.md` entries under `[Unreleased]` match what actually merged since last tag

## v1.0.0 — 15-step release-day runbook

1. **Confirm `main` is green** (see pre-release gate above).
2. `git checkout -b release-1.0 main` — optional release branch. Defer merges back to `main` post-release.
3. **Run final smoke tests** on wiped macOS 14 + macOS 15 VMs with the unsigned debug build.
4. **Bump versions.** Update `Info.plist`:
   - `CFBundleShortVersionString=1.0.0`
   - `CFBundleVersion=10000` (Sparkle integer; monotonic)

   Commit: `release: bump version to 1.0.0`.
5. **Generate changelog**: `git cliff --unreleased --tag v1.0.0 -p CHANGELOG.md`. ❗ Hand-curate the highlights section.
6. **Sign the tag**: `git tag -s v1.0.0 -m "SolidTerm 1.0.0"`.
7. **Push**: `git push origin release-1.0 v1.0.0`.
8. **Watch the `release` workflow in GitHub Actions**. Confirm each step:
   - Build ✅
   - Codesign ✅
   - Notarize → `Status: Accepted` (90 min timeout; on hang, check notary.apple.com status page)
   - Staple validated ✅
   - Upload to R2 (dmg, update.zip, dSYM) → 200
   - Appcast.xml uploaded **last** ✅
   - Cask PR auto-merged on `ZEN-ZAI/homebrew-solidterm` ✅
9. **❗ Manual gate**: download the DMG over a clean network, mount, verify Gatekeeper accepts ("Apple checked it for malicious software and none was detected"), drag to Applications, launch.
10. **❗ Manual gate**: trigger a Sparkle update from a preserved v0.9.x build (kept in `~/Tools/solidterm-test-builds/`). Confirm: appcast loads, EdDSA signature verifies, in-place install completes.
11. **Publish website** release announcement (linked to GH release).
12. **Announce**: r/macapps, IndieHackers, Mastodon (`@brentsimmons`-style indie circles), Hacker News (Show HN).
13. **❗ 24 h freeze.** Do not change anything. Watch GitHub issues. If a P0 surfaces → cut `v1.0.1` rather than re-tagging `v1.0.0`.
14. **Day +3**: open Homebrew/homebrew-cask PR to migrate from the self-hosted tap (or defer until star count clears 225).
15. **Day +7**: archive `release-1.0` branch state, merge any cherry-picks back to `main`, start on `release-1.1`.

## Beta release (0.x or 1.x-beta.N)

Shorter version of the above — same steps 1-8, skip the 24 h freeze, publish to the `beta` Sparkle channel only.

```bash
git tag -s v1.0.0-beta.1 -m "SolidTerm 1.0.0-beta.1"
git push origin v1.0.0-beta.1
```

Sparkle maps pre-release semver (`-beta.N`, `-rc.N`) to the `beta` channel via `<sparkle:channel>` in the appcast; stable users never see it unless they opt in with:

```bash
defaults write dev.solidterm.app SUChannel beta
```

## Rollback procedure

If a released DMG is found to crash or ship a regression:

1. **Pull the appcast**: delete the offending entry from `appcast.xml` on R2 so new installs don't see it.
2. **Already-installed users**: Sparkle only moves forward; ship `v1.0.1` ASAP rather than downgrading.
3. **Cask PR**: revert to prior SHA256 / version in the tap (`ZEN-ZAI/homebrew-solidterm`).
4. **Do NOT delete the GitHub release** — keep it for audit / forensics. Add a `!!! SUPERSEDED BY v1.0.1` notice to the release body.
5. **Write a postmortem** in `vault/incidents/YYYY-MM-DD-<slug>.md`.

## Notarization recovery

If `notarytool submit` times out or errors:

- `xcrun notarytool history --keychain-profile NEXTTERM_NOTARY` — list recent submissions
- `xcrun notarytool info <submission-id> --keychain-profile NEXTTERM_NOTARY` — detail
- `xcrun notarytool log <submission-id> --keychain-profile NEXTTERM_NOTARY` — reason for rejection
- Most common rejections: missing entitlement justification, unsigned nested binary, `allow-unsigned-executable-memory` without reason

## Secrets checklist (GitHub Actions)

All managed in repo Settings → Secrets and variables → Actions:

- [ ] `APPLE_DEVELOPER_ID_CERT_P12` — base64-encoded Developer ID Application cert
- [ ] `APPLE_DEVELOPER_ID_CERT_PASS` — passphrase for the p12
- [ ] `NOTARY_API_KEY_P8` — App Store Connect API key (base64 of the `.p8`)
- [ ] `NOTARY_API_KEY_ID`
- [ ] `NOTARY_ISSUER_ID`
- [ ] `SPARKLE_ED_PRIVATE` — Sparkle EdDSA private key (base64)
- [ ] `R2_ACCESS_KEY` / `R2_SECRET_KEY`
- [ ] `HOMEBREW_TAP_TOKEN` — fine-grained PAT for `ZEN-ZAI/homebrew-solidterm` write

## Costs (as of 2026-04)

| Item | Cost | Frequency |
|---|---|---|
| Apple Developer Program | $99/yr | annual |
| Domain (`solidterm.app`) | ~$20/yr | annual |
| Cloudflare R2 (appcast + DMGs) | <$5/mo | monthly |
| App Store Connect API key | free | annual rotation |

## See also

- `vault/research/15-release-engineering.md` — full reasoning + CI yml sketch
- `vault/decisions/02-distribution.md` — direct + brew cask strategy
- `vault/decisions/03-telemetry.md` — no auto-upload crash reports
