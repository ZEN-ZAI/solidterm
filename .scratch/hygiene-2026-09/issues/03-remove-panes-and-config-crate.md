# 03 — Remove panes.rs and the solidterm-config placeholder crate

Status: done — 2026-09-06
Blocked by: 01
Spec: ../spec.md (D3, D4)

## Steps

1. Delete `crates/solidterm-engine/src/panes.rs`; remove `pub mod panes;` and the re-export block (`LayoutRect, PaneId, PaneNode, PaneTree, SplitDirection, SplitError, SplitId, DEPTH_CAP`) from `src/lib.rs`.
2. Delete `crates/solidterm-config/`; remove it from `[workspace].members` in root `Cargo.toml`; `cargo update` will drop it from `Cargo.lock`.
3. Docs to match:
   - `CLAUDE.md`: repo layout block (2 crates, drop the config line), "What's IN" bullet → "Window/tab chrome (single pane per window; no split panes)".
   - `AGENTS.md:26` crate list.
   - `app/project.yml:139` comment ("solidterm-engine / solidterm-config" → "solidterm-engine").
   - `app/SolidTerm/PaneSplitter.swift` header comment is already accurate; leave.

## Verify

```
cargo test --workspace          # 273 passed (288 − 15 panes tests)
grep -rn 'panes::\|PaneTree\|solidterm-config\|solidterm_config' crates app CLAUDE.md AGENTS.md   # nothing
scripts/check-ffi-drift.sh
cd app && xcodebuild test -scheme SolidTerm -destination 'platform=macOS'
```

## Comments

### 2026-09-06 — landed

One commit: `refactor: drop the dead panes module and the config placeholder crate`
(this commit).

All three steps done. `crates/solidterm-engine/src/panes.rs` (568 lines, 15 tests)
is gone along with `pub mod panes;` and the eight-name re-export block in
`src/lib.rs`; nothing else in `crates/`, `app/` or `scripts/` named any of them.
`crates/solidterm-config/` (a two-file placeholder: `pub struct Config;`) is gone
with its `[workspace].members` entry, leaving the workspace at
`solidterm-engine` + `solidterm-ffi`. Docs match: CLAUDE.md's layout block reads
"2 crates" without the config line and its feature bullet now reads
"Window/tab chrome (single pane per window; no split panes)"; `AGENTS.md:26` and
the `app/project.yml` build-phase comment name only `solidterm-engine`.

Tallies: `cargo test --workspace` 273 passed, 0 failed — exactly the 288 − 15 this
ticket predicted. `xcodebuild test` Executed 446 tests, 2 skipped, 0 failures. (An
earlier run of the same tree reported 2 failures, both assertions of the known-flaky
`CopyPasteTests.testPasteConsultsBracketedPasteFlag`; it passed alone and the
pre-commit run was clean.) `cargo fmt --check`, `cargo clippy --workspace
--all-targets --all-features` under `RUSTFLAGS=-D warnings`, `check-ffi-drift.sh`,
the three custom lint scripts and `swift-format lint --strict` all exit 0.

Judgement calls:

- **Step 3's file list was one short.**
  `app/SolidTerm/PaneViewController.swift:39` documented its `paneId` as
  "matches `solidterm_engine::PaneId`" — a type step 1 deletes. Left alone it
  would be the one dangling reference this change creates, and step 3 is headed
  "Docs to match", so the comment now reads "Pane id, unique within the window
  that owns this pane." Comment-only; no Swift behaviour changed.
- **The Verify grep cannot reach zero, and shouldn't.** It matches `PaneTree`,
  which is a substring of `WindowPaneTree` in `app/SolidTerm/PaneSplitter.swift:5`
  — prose recording that a Rust-side type was removed, not a live reference. Step
  3's last bullet says to leave that header, so the grep returns exactly that one
  hit. The header's remaining wording is ticket 18's (identity) to rewrite, not
  this one's.
- **`cargo update` was not run.** Step 2 offers it as the way to drop the crate
  from `Cargo.lock`, but a bare `cargo update` re-resolves every dependency and
  would undo ticket 01's targeted `crossbeam-epoch` 0.9.21 pin. `cargo check`
  prunes the one `[[package]]` entry instead: the lockfile diff is 4 deleted lines.
- **`xcodegen generate` was not run.** The `project.yml` edit is a YAML comment
  outside the build phase's `script:` string, so it never reaches
  `project.pbxproj` (confirmed: the comment text does not appear there) and the
  generated project is unchanged.
