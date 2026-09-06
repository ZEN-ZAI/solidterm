# 05 — Tag v0.4.12, harden build-release-dmg.sh, backfill CHANGELOG

Status: done — 2026-09-06
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

## Comments

### 2026-09-06

One commit: `build(release): tag v0.4.12, guard the DMG script, backfill CHANGELOG` (this commit).

All three steps landed together. The annotated tag `v0.4.12` was created locally at `502ff17` with
the dictated message; `git tag -l` lists `v0.1.0 v0.4.12` and `git describe --tags 502ff17` answers
`v0.4.12`. `scripts/build-release-dmg.sh` gained the dirty-tree refusal, the already-tagged refusal,
the `SolidTermGitCommit` stamp with the re-sign after it, and the post-DMG annotated tag plus the
printed push command; the header comment now describes all four. `CHANGELOG.md` gained
`## [0.4.12] — 2026-08-17` built from the 58 commits in `v0.1.0..502ff17`, and `## [Unreleased]`
holds the five entries the ticket lists.

Judgement calls: one commit rather than three, because the tag, the script and the changelog section
are one release-hygiene statement and neither of the first two is meaningful alone. A third link ref
for `[Unreleased]` was added beyond the "two tags" the ticket asks for — Keep a Changelog compares
`[Unreleased]` to `HEAD`, and omitting it would leave the heading unlinked. The Ctrl-C entry was
moved byte-for-byte rather than reworded, since the ticket says move. Commits with no user-visible
effect were left out of the section, including a feature that was reverted before the tag. The
already-tagged guard cannot fire in this checkout (the dirty-tree guard precedes it and the tree is
dirty mid-ticket), so it was exercised against a throwaway clean repo under `$TMPDIR`: it printed
`refusing: tag v0.4.12 already exists` and exited 1.

Not done here: `## [0.1.0]` is byte-identical to before — ticket 18 rewrites it. Nothing was pushed
and the tag was not pushed; ticket 17 does that with approval. `MARKETING_VERSION` stays `0.1.0`,
since D6 makes the version argument the single source.

Gates before the commit: `cargo test --workspace --all-features -j 8` → 273 passed, 0 failed, with
fmt, clippy `-D warnings`, ffi-drift and the three lint scripts all exit 0; `xcodebuild test -scheme
SolidTerm -destination 'platform=macOS'` → `** TEST SUCCEEDED **`, Executed 446 tests, 2 skipped,
0 failures.
