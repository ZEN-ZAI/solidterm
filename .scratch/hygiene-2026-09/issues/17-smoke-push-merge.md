# 17 — Manual smoke, push, CI, ff-merge

Status: done — 2026-09-07
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

### 2026-09-07 — checkpoints pushed, smoke run, branch merged

`main` and `chore/hygiene-2026-09` were pushed on 2026-09-07; the branch fast-forwarded
into `main` at `6ede22f` and the `v0.4.12` tag was pushed with it. CI does not run on
branch pushes (the workflow triggers on `main` and pull requests only), and the
maintainer chose not to open a PR, so the first full CI run over this work is the one
`main` gets after the merge.

Smoke was driven against a Release build, copied aside and re-signed under the bundle id
`com.zenzai.SolidTerm.smoke` with `SOLIDTERM_JOURNAL_PATH` pointed at a temp file, so the
maintainer's own instance, window state and defaults were never touched.

Verified with file-level oracles rather than by eye:

- keystrokes reach the shell; `Ctrl-C` still interrupts after a `⌘C` (the wedge repro)
- a 200-line paste arrives byte-for-byte identical
- bracketed paste is exact: `PAYLOAD\n` with DECSET 2004 off, `ESC[200~PAYLOAD\nESC[201~` with it on
- `⌘W` during a 50 MB flood closes the window, leaves the app alive and `⌘N` still works
- the About panel reads "Built on alacritty_terminal + swift-bridge" plus the
  Acknowledgements link, and the copyright line carries no lineage sentence
- display sleep: a 2 s tick loop wrote 82 ticks across 163 s with a 3 s maximum gap, so
  the pane never stalled while the screen was dark

Three items were not reachable from a script and stay on the maintainer's eyes: dragging
files out of Finder (covered by `DragDropTests`), the find bar's match counter (the panel
is SwiftUI and exposes no accessibility labels), and confirming `ทำ` and `🇹🇭` each render
as one cluster (screen capture is denied to the automation process). Real Thai IME
composition also stays manual: the Thai source is a keyboard layout, not an input method,
so there is no preedit to interrupt, and no CJK input method is installed on this machine.

