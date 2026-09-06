# 12 — Move inline `mod tests` out of the large Rust files

Status: done — 2026-09-06
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

## Comments

### 2026-09-06 — landed

One commit: `refactor: move the six inline test modules into their own files`
(this commit). Step 3 allows one commit per crate or one total; one total, because
the move is a single mechanical operation over both crates and splitting it would
buy a second full gate cycle and nothing else.

All six blocks moved. Each parent keeps its `#[cfg(test)]` line and now reads
`mod tests;`; the body went to `<mod>/tests.rs` as a child module, so `use super::…`
still reaches the parent's private items and every test path (`engine::tests::…`)
is unchanged. `git diff --stat` is exactly the 12 files the ticket names, and the
only line added to any of the six parents is `mod tests;` — the deletions run from
`mod tests {` to EOF and touch no production item.

Extraction was verbatim, then `cargo fmt --all` (step 2) dedented the bodies. The
dedent let rustfmt rejoin lines that now fit inside 100 columns: 8 in
`engine/tests.rs`, 4 in `cells/tests.rs`, none elsewhere — which is why those two
files are 8 and 2 lines shorter than the blocks they came from. Verified
content-preserving two ways: the whitespace-free text of each moved body is
byte-identical to the original, and the `#[test]` name sets match exactly
(engine 85, events 40, osc 37, bridge 14, cells 13, search 10 = 199).

Tallies: `cargo test --workspace` 273 passed, 0 failed (207 + 3 + 1 + 1 + 3 + 44 +
14 across 8 suites); `xcodebuild test` Executed 482 tests, 3 skipped, 0 failures.
The rest of Verify is green too: `cargo fmt --all -- --check` clean,
`RUSTFLAGS='-D warnings' cargo clippy --workspace --all-targets --all-features`
clean, `scripts/check-ffi-drift.sh` reports "FFI shims in sync" (the bridge module
itself did not change, so `app/SolidTerm/Generated/` is untouched), and
`check-no-analytics.sh` / `check-license-headers.sh` / `check-ai-authored-tests.sh`
all exit 0.

Judgement calls:

- **The Files table's line numbers are stale for two rows.** `engine.rs` has
  `mod tests` at 1944 of 4900 (table: 1931 / 4885) and `events.rs` at 480 of 1284
  (table: 479 / 1283) — earlier hygiene tickets grew both files after the spec's
  "Facts gathered" was written. `osc`, `bridge`, `cells` and `search` still match
  the table exactly. The tree wins: the block was located by its `#[cfg(test)]`
  attribute, not by line number, so the right six blocks moved.
- **`.git-blame-ignore-revs` was not touched.** CONTRIBUTING.md asks for an entry
  "whenever another tree-wide pass lands", but this is a move, not a reformat, and
  every reflowed line lives in a file that did not exist before — blame has no
  earlier revision to fall through to, so an ignore entry would point at nothing.
- **Nothing was cleaned up on the way past.** Review flagged three things the move
  carries over unchanged: `fn feed` is duplicated between `search/tests.rs` and
  `bridge/tests.rs`, two `engine.rs:NNN` citations in `events/tests.rs` now name
  the wrong lines, and `engine/tests.rs` is at 2947 lines the crate's largest
  file. A pure move stays pure; the citations are ticket 19's, and the spec's
  Non-goals rule out splitting test modules further.
