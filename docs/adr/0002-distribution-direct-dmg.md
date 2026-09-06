# ADR-0002 — Beta distribution is a direct, ad-hoc-signed DMG

Status: accepted

## Context

SolidTerm needs to reach beta users before it is worth paying for and
maintaining the full Apple distribution chain. The options were: enrol in the
Apple Developer Program now and ship Developer-ID-signed, notarized builds with
a Sparkle auto-updater and a Homebrew cask; or ship a plain DMG and let users
accept the Gatekeeper warning once.

The full chain costs $99/yr plus a domain and object storage for the appcast,
and it introduces machinery — a notarization submission, an appcast, a tap —
that has to work on every release from the first one. The plain DMG costs a
first-launch right-click and a sentence of instructions.

## Decision

Beta releases are unsigned, ad-hoc-signed `.dmg` files built by
`scripts/build-release-dmg.sh` and handed to users directly.

The script is the release path, and it is tag-driven and reproducible from git
alone:

- it refuses to build from a dirty working tree, so a DMG always corresponds to
  a commit that exists;
- it refuses to rebuild a version already tagged in this clone, so one version
  cannot produce two binaries;
- it stamps the short HEAD sha into `Info.plist` as `SolidTermGitCommit` and
  re-signs the bundle, so a shipped `.app` traces back to its source;
- it creates the annotated tag `v<version>` after the DMG is written and prints
  the push command rather than pushing for you.

Deliberately not implemented, and deliberately not "missing": Developer ID
signing, `notarytool` submission and stapling, the hardened runtime, a Sparkle
appcast, a Homebrew cask, and a CI release workflow. `docs/release-runbook.md`
describes that target state and is marked as such; nothing in the repository
depends on it today.

## Consequences

- First launch shows a Gatekeeper warning. Users must right-click → Open once.
  `docs/SECURITY.md` says so plainly and tells people to install only DMGs they
  got from the maintainer or over HTTPS from a URL the maintainer gave them.
- There is no auto-update. New versions are announced and downloaded manually.
- Releases are cut by hand. The gate is the script's own refusals plus the
  runbook checklist, not a CI job.
- Moving to the signed path is additive: add `codesign --options runtime`,
  re-enable `ENABLE_HARDENED_RUNTIME` in `app/project.yml`, add `notarytool
  submit --wait` and `stapler staple`, and settle the bundle identifier. That
  change supersedes this ADR rather than amending it.
