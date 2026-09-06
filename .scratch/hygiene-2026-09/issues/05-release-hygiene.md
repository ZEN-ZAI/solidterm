# 05 — Tag v0.4.12, harden build-release-dmg.sh, backfill CHANGELOG

Status: ready-for-agent
Blocked by: 01
Spec: ../spec.md (D6, D7)

## Steps

1. Tag (local only until push is approved):
   `git tag -a v0.4.12 502ff17 -m "SolidTerm 0.4.12 — reconstructed: dist/SolidTerm-0.4.12.dmg was built 18 s after this commit (2026-08-17 23:11 +0700)"`
2. `scripts/build-release-dmg.sh`:
   - after arg parsing: `[[ -z "$(git status --porcelain)" ]] || { echo "refusing: working tree dirty" >&2; exit 1; }`
   - refuse if `git rev-parse -q --verify "refs/tags/v$VERSION"` already exists;
   - after staging the app: `/usr/libexec/PlistBuddy -c "Add :SolidTermGitCommit string $(git rev-parse --short=10 HEAD)" "$DMG_STAGE/SolidTerm.app/Contents/Info.plist"` then `codesign --force --sign - --deep "$DMG_STAGE/SolidTerm.app"` (editing Info.plist breaks the ad-hoc seal; re-sign);
   - after the DMG is written: `git tag -a "v$VERSION" -m "SolidTerm $VERSION"` and print "push with: git push origin v$VERSION";
   - update the header comment to describe the guard/tag/stamp behaviour.
3. `CHANGELOG.md`:
   - new section `## [0.4.12] — 2026-08-17` built from `git log v0.1.0..502ff17` (58 commits) grouped Added / Changed / Fixed; use commit bodies (844 lines) for the root-cause sentences; move the existing Ctrl-C entry here.
   - `## [Unreleased]` = display-sleep entry (already there) + `7e869e4` window-close deadlock, `e4fc331` selection follows scroll, `a9319c6` ⌥/⌘-drag over mouse-capturing TUI, `03f0168` OSC title revert.
   - keep Keep-a-Changelog format; add link refs for the two tags at the bottom.
   - wording rule (D13): no entry under `[0.4.12]` or `[Unreleased]` contains the word NextTerm — e.g. `203b86f` becomes "Changed: internal identifiers unified under the SolidTerm name". Ticket 18 rewrites `[0.1.0]` separately; do not touch it here.

## Verify

```
git tag -l                        # v0.1.0 v0.4.12
git describe --tags 502ff17       # v0.4.12
bash -n scripts/build-release-dmg.sh
# dry-run the guard: touch a file, run the script, expect "refusing"; remove the file
```

## Notes

Do not push the tag in this ticket; ticket 17 pushes with approval.
