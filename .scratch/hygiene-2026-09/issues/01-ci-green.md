# 01 — CI green: fmt, warnings, deps audit, toolchain, job graph

Status: ready-for-agent
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
