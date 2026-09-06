# 12 — Move inline `mod tests` out of the large Rust files

Status: ready-for-agent
Blocked by: 01
Spec: ../spec.md (D8)

## Files (mod tests line / total)

| File | `mod tests` | total | new file |
|---|---|---|---|
| `crates/solidterm-engine/src/engine.rs` | 1931 | 4885 | `src/engine/tests.rs` |
| `crates/solidterm-engine/src/events.rs` | 479 | 1283 | `src/events/tests.rs` |
| `crates/solidterm-engine/src/osc.rs` | 506 | 1030 | `src/osc/tests.rs` |
| `crates/solidterm-ffi/src/bridge.rs` | 922 | 1160 | `src/bridge/tests.rs` |
| `crates/solidterm-engine/src/cells.rs` | 339 | 601 | `src/cells/tests.rs` |
| `crates/solidterm-engine/src/search.rs` | 178 | 316 | `src/search/tests.rs` |

## Steps

1. For each file: cut the body of `mod tests { … }` into `<mod>/tests.rs` verbatim (keep `use super::…`; a child module still sees the parent's private items), and leave `#[cfg(test)] mod tests;` in place of the block. Rust 2018 layout allows `engine.rs` alongside `engine/`.
2. Run `cargo fmt --all` on the new files; do not reflow anything else.
3. One commit per crate (engine, ffi) or one commit total — keep the diff a pure move (`git diff --stat` shows only these 12 files).

## Verify

```
cargo test --workspace                 # same count as after ticket 03 (273)
RUSTFLAGS='-D warnings' cargo clippy --workspace --all-targets --all-features
scripts/check-ffi-drift.sh             # bridge module unchanged → shims unchanged
```
