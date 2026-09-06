# 03 — Remove panes.rs and the solidterm-config placeholder crate

Status: ready-for-agent
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
