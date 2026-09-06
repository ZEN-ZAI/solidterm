# 01 — CI green: fmt, warnings, deps audit, toolchain, job graph

Status: done — 2026-09-06
Blocked by: —
Spec: ../spec.md (D1)

## Goal

Every CI job passes on the branch, and a lint failure can no longer skip the test jobs.

## Steps

1. `cargo fmt --all` (fixes `engine.rs` 1450, 3184, 3191, 4540).
2. Warnings that become errors under `RUSTFLAGS=-D warnings`:
   - `crates/solidterm-engine/src/engine.rs:607` — add `#[allow(unsafe_code)]` on the enclosing fn (the SAFETY comment is already there; keep it).
   - `engine.rs:613` — drop `Some(libc::EWOULDBLOCK)` from the match arm (equal to `EAGAIN` on macOS; the crate is macOS-only). Leave a one-line comment.
   - `crates/solidterm-engine/src/events.rs:327` — mark `EventProxy::new` `#[cfg(test)]`.
3. `cargo update -p crossbeam-epoch` (0.9.18 → 0.9.21, RUSTSEC-2026-0204). Commit `Cargo.lock`.
4. `rust-toolchain.toml`: remove the `targets` line (rustup installs the host target; app is arm64-only). Keep `channel = "1.89.0"`.
5. `.github/workflows/ci.yml`:
   - remove `needs: rust-fmt-clippy` from `rust-test`, `ffi-drift`, `swift-test`;
   - delete the commented-out `bench-drift` and `fuzz-smoke` blocks and the "Jobs below land…" banner;
   - fix the header comment ("Phase 0 …") to describe the current job set.
6. Stale comments: `app/scripts/build-rust.sh` (mentions `solidterm-claude`), `app/project.yml` theme comment ("zenzai, tokyo-night, gruvbox, light" → "20 bundled themes under Resources/Themes").

## Verify

```
cargo fmt --all -- --check
RUSTFLAGS='-D warnings' cargo clippy --workspace --all-targets --all-features
cargo test --workspace
cargo deny check advisories   # if cargo-deny is installed locally; otherwise rely on CI
scripts/check-ffi-drift.sh
```

## Out of scope

swift-format (ticket 02). Any behaviour change.

## Comments

### 2026-09-06 — landed

One commit: `chore(ci): make every CI job pass and stop lint from skipping tests`
(the single commit of this ticket; SHA in `git log`).

All six steps done. `cargo fmt --all` reflowed the four `engine.rs` sites the spec
listed. The three named warnings are fixed at the source (`#[allow(unsafe_code)]` on
`feed_input_nonblocking` keeping its SAFETY note, the unreachable
`Some(libc::EWOULDBLOCK)` arm dropped with a one-line note, `EventProxy::new` marked
`#[cfg(test)]`). `crossbeam-epoch` 0.9.18 → 0.9.21 clears RUSTSEC-2026-0204.
`rust-toolchain.toml` lost its `targets` line. `ci.yml` lost all three
`needs: rust-fmt-clippy` edges, the commented-out `bench-drift` / `fuzz-smoke` blocks
and their banner, and its header now names the six jobs that exist.

Judgement calls:

- **Step 2 was under-enumerated.** It names three rustc warnings, but
  `[workspace.lints.clippy] pedantic = warn` plus the workflow-wide
  `RUSTFLAGS: -D warnings` also makes 13 clippy diagnostics hard errors across six
  files (`engine.rs`, `events.rs`, `osc.rs`, `cells.rs`, `search.rs`,
  `tests/teardown_detached.rs`): `doc_markdown`, `cast_sign_loss`,
  `cast_possible_wrap`, `items_after_statements`. The Goal ("every CI job passes")
  and the Verify block both require clippy to be clean, so they are fixed here, in
  the crate's existing per-statement `#[allow(clippy::…)]` style. No behaviour change.
- **`build-rust.sh`** now reads `solidterm-engine, …` rather than naming
  `solidterm-config`, which ticket 03 deletes — otherwise the comment would go stale
  again one ticket later.
- **`ci.yml` header** was rewritten in place, two lines for two, so the design-archive
  pointer stays on line 6 where ticket 18's inventory expects it.
- **Removing `needs:`** means a PR with a fmt slip now still spends the two-OS
  `xcodebuild clean test` matrix. Deliberate: that cost is what makes the jobs a gate.

Left for other tickets: `project.yml:139` (`solidterm-config`, ticket 03); the
design-archive pointer at `ci.yml:6` (ticket 18); swift-format, so the `swift-test`
job's lint step stays red until ticket 02. Flagged, owned by nobody:
`crates/solidterm-engine/tests/fuzz_inputs.rs:2` names a crate that no longer exists —
same class as step 6 but outside its three named files.

Tallies before the commit: `cargo test --workspace` 288 passed, 0 failed;
`xcodebuild test` Executed 446 tests, 2 skipped, 2 failures — both assertions of
`testPasteConsultsBracketedPasteFlag`, the known PTY-echo flake, which passes on an
isolated rerun (Executed 1 test, 0 failures). `cargo fmt --all -- --check` clean;
`RUSTFLAGS='-D warnings' cargo clippy --workspace --all-targets --all-features` exit 0;
`cargo deny check advisories` → advisories ok; `scripts/check-ffi-drift.sh` → in sync;
all three custom lint scripts exit 0.
