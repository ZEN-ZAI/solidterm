# 17 — Manual smoke, push, CI, ff-merge

Status: ready-for-human
Blocked by: 13, 14, 15, 16, 18, 19, 20
Spec: ../spec.md (D11, D12)

## Push checkpoints (each needs explicit approval)

1. After ticket 18 (05 + identity): push `chore/hygiene-2026-09` → confirm all 6 CI jobs green (fmt+clippy, Rust test, FFI drift, deps audit, custom lints, Swift test ×2). Do not push the `v0.4.12` tag yet.
2. After ticket 12: push → CI green.
3. After ticket 20: push → CI green.

## Manual smoke (maintainer, Release build)

Build: `cd app && xcodebuild build -scheme SolidTerm -configuration Release -destination 'platform=macOS'`; open the app at `$(xcodebuild -showBuildSettings … | awk '/BUILT_PRODUCTS_DIR/{print $3}')/SolidTerm.app` (never `find` DerivedData).

- [ ] Thai input via IME: type `ทำ ก่อ สวัสดี` mid-line, backspace through it, ⌘C/⌘V mid-composition then Ctrl-C reaches the shell.
- [ ] Paste 200 multi-line rows into `cat`, then into `vim` (bracketed paste).
- [ ] Drag two files (one with a space) from Finder into the prompt → shell-quoted, space-separated.
- [ ] `yes | head -c 50M` then ⌘W during the flood → window closes, app stays responsive.
- [ ] ⌘F search for a regex in scrollback → highlights and counter update; Esc returns focus to the terminal.
- [ ] SolidTerm ▸ About SolidTerm shows the new credits (no fork line); version + copyright read from Info.plist; the Acknowledgements link opens the bundled THIRD_PARTY_NOTICES.md.
- [ ] Type `ทำ` and `🇹🇭` — each renders as one cluster (shaping default ON with the `NEXTTERM_SHAPING` fallback gone).
- [ ] Close the lid / display sleep 2 min with `ping 127.0.0.1` running → output continued (no 2-minute gap on wake).

## Merge

`git checkout main && git merge --ff-only chore/hygiene-2026-09 && git push origin main v0.4.12` (with approval). Then the maintainer may cut `0.4.13` with `scripts/build-release-dmg.sh 0.4.13`.

## Comments
