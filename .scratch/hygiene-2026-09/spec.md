# Hygiene 2026-09 — CI green, dead code, docs, versioning, big-file splits, identity, license

Status: ready-for-agent
Origin: project analysis + grilling session, 2026-09-06; identity grilling 2026-09-06 (D13, D14); license grilling 2026-09-06 (D15)
Branch: `chore/hygiene-2026-09` (ff-merge into `main` once CI is green)

## Why

The 2026-09-06 analysis found the code healthy (288 Rust + 446 Swift tests
pass locally) but the repo around it drifted:

- CI red for 5 consecutive runs since a5f963b (2026-06-17): rustfmt dirty,
  RUSTSEC-2026-0204 in a dev-dep, toolchain override breaks the ubuntu job.
  Because every test job has `needs: rust-fmt-clippy`, Rust test / FFI drift
  / Swift test have been *skipped* for three months.
- Dead code: `crates/solidterm-engine/src/panes.rs` (568 lines, 15 tests,
  never wired to FFI or Swift) and the placeholder crate `solidterm-config`.
- Docs still describe NextTerm (Claude integration, hooks, beta programme,
  `NEXTTERM_NOTARY`), and `CLAUDE.md` claims split panes that don't exist.
- Releases are invisible to git: only tag `v0.1.0`, but `dist/` holds
  local DMGs up to 0.4.12; `CHANGELOG.md` is ~10 entries behind.
- Monolith files: `MetalRenderer.swift` 3,230 / `TerminalSurfaceView.swift`
  2,540 / `GlyphAtlas.swift` 1,900 / `BoxDrawing.swift` 1,548 lines;
  `engine.rs` 4,885 lines of which 2,955 are inline tests.

## Goals

1. CI is a real gate again and green on every job.
2. No unreachable code or placeholder crates in the workspace.
3. Every doc in the repo describes SolidTerm as it is today.
4. Git tags are the source of truth for what has shipped.
5. Large files split along existing seams, protected by tests added first.

## Non-goals

- No behaviour changes. No new features. No new sub-object extraction
  (SelectionController etc.) — extension-per-file only.
  Single exception (D13b): ticket 18 removes two legacy compatibility names
  (`NEXTTERM_SHAPING`, `_NEXTTERM_INTEGRATION_LOADED`) in its own commit.
- No signing / notarization / Sparkle work (release-runbook target state
  stays a target).
- No touching `~/Vaults`. The design vault was removed on 2026-09-06; the repo cuts
  every live pointer to it (D13c) and retires the remaining citations (D14).

## Decisions (grilled 2026-09-06)

| # | Decision |
|---|----------|
| D1 | CI is a real gate. Fix everything; remove `needs:` from test jobs so a lint failure no longer skips tests; delete the commented-out `bench-drift` / `fuzz-smoke` jobs (they reference a non-existent fuzz target and `solidterm-claude`). |
| D2 | swift-format: one mechanical `swift-format format -i` commit over all 38 files + hand-fix the 19 `LineLength` hits; add `.git-blame-ignore-revs`; keep `lint --strict` in CI. |
| D3 | Delete `panes.rs` + its `lib.rs` re-exports. `CLAUDE.md` says single pane per window + tabs. |
| D4 | Delete crate `solidterm-config`. Workspace = `solidterm-engine` + `solidterm-ffi`. Config stays Swift-side (UserDefaults, TOML themes, keybindings). |
| D5 | Docs: delete `docs/BETA.md`, `.github/ISSUE_TEMPLATE/beta_feedback.md`, `docs/prompts/`, `tests/fixtures/{claude-md,stream-json,settings}`; rewrite `docs/SECURITY.md`; fix `release-runbook.md` profile name; fix Claude lines in `bug_report.md` / PR template; fix stale comments in `ci.yml`, `build-rust.sh`, `project.yml`. |
| D6 | Tag-driven versioning. Tag `v0.4.12` at `502ff17` now (DMG 0.4.12 was built 18 s after that commit). No older backfill. `build-release-dmg.sh` gains: refuse dirty tree, create annotated tag `v<version>`, stamp git sha into Info.plist. `MARKETING_VERSION` in `project.yml` stays `0.1.0`; the script argument is the single source of the version. |
| D7 | CHANGELOG: backfill one `[0.4.12] — 2026-08-17` section from the 58 commits `v0.1.0..502ff17`; `[Unreleased]` keeps only the 5 fixes after it (move the Ctrl-C entry down into 0.4.12). Hand-written, keep the root-cause narrative style. No git-cliff. |
| D8 | Split scope (full): `MetalRenderer`, `TerminalSurfaceView`, `GlyphAtlas`, `BoxDrawing`; Rust: move `mod tests` out of `engine`, `events`, `osc`, `bridge`, `cells`, `search` into `<mod>/tests.rs`. |
| D9 | Split mechanism: extensions of the same type across files; `private` members that must cross a file boundary become `internal` (still module-private). No new types. |
| D10 | Tests before splitting (full set): shared Metal offscreen harness; clock injection on the renderer + idle-pump test; pixel tests for all 8 overlay encoders; font-size methods; `computeCursorBlockState`; drag-drop; BoxDrawing golden hash over every handled codepoint. |
| D11 | Acceptance: every commit passes `cargo test --workspace` and `xcodebuild test`; CI green on the branch; manual smoke (5 items) on a Release build after the splits; test counts never drop below 288 Rust / 446 Swift. |
| D12 | Execution: record plan in `.scratch/` (this), work on branch `chore/hygiene-2026-09`, push only with explicit approval at phase ends, ff-merge to `main` when CI is green. |
| D13 | SolidTerm stands on its own (grilled 2026-09-06). (a) `CHANGELOG [0.1.0]` rewritten as an initial release, zero NextTerm. (b) Remove the legacy `NEXTTERM_SHAPING` env fallback and the `_NEXTTERM_INTEGRATION_LOADED` shell guards — the branch's single behaviour change, own commit. (c) Cut the design vault: delete every live pointer (`vault/…`, `~/Vaults/…`, "(vault)") and the `.gitignore` symlink lines; `~/Vaults` itself is not touched. (d) Rewrite the five `.claude/agents/*.md` against the real tree; delete `spec-keeper.md`. (e) Three ADRs written from what the repo enforces: no-telemetry, direct-DMG distribution, Swift-side cross-cell shaping (`ADR-19` → `ADR-0003`). (f) Fixture prose and the `engine.rs` title-test string say SolidTerm; `osc-sequences/*.bin` bytes untouched. (g) `CLAUDE.md` / `AGENTS.md` keep the guardrail list as "Out of scope", phrased as scope, never as fork/stripped. (h) License: decided the same day as GPL-3.0-or-later (D15); 18 writes the final license wording into `CONTRIBUTING.md:78`, `deny.toml`, `check-license-headers.sh`; ticket 20 applies the license. (i) Ticket 18, blocked by 03/04/05, runs right after 05, four commits by concern. |
| D14 | Retire design-archive citations: the ~165 remaining `spec/*.md §…`, `decisions/NN`, `research/NN` citations in code comments are replaced by the information they carried (or `(design archive)` when unrecoverable), with new ADRs only where code pins a durable rule. Ticket 19, after 13-16 and 18, comment-only. |
| D15 | License (grilled 2026-09-06, record in `.scratch/choose-license/spec.md`): **GPL-3.0-or-later** for the whole repo — intent "anyone may use and modify, nobody may take it proprietary"; permissive licenses cannot say that, source-available ones are not open source. SPDX two-line headers on all 121 source files (`Generated/` excluded) enforced by `scripts/check-license-headers.sh`; theme TOMLs get palette attribution; `THIRD_PARTY_NOTICES.md` generated from the crates linked into the binary + swift-bridge runtime + palettes, committed, bundled in the app, linked from About, CI fails when stale; CONTRIBUTING keeps the maintainer relicense clause, no DCO; ADR + `license = "GPL-3.0-or-later"` in `[workspace.package]`. Ticket 20, after 18 + 19, before 17. |

## Facts gathered (so tickets don't re-derive them)

- rustfmt diffs: `crates/solidterm-engine/src/engine.rs` at 1450, 3184, 3191, 4540.
- rustc warnings (errors under CI `RUSTFLAGS=-D warnings`): `engine.rs:607` unsafe block without `#[allow(unsafe_code)]` (SAFETY comment already present); `engine.rs:613` `Some(libc::EWOULDBLOCK)` unreachable (== `EAGAIN` on macOS); `events.rs:327` `EventProxy::new` only used by tests.
- RUSTSEC-2026-0204: `crossbeam-epoch 0.9.18` via `criterion 0.5 → rayon`; `cargo update -p crossbeam-epoch` → 0.9.21.
- `rust-toolchain.toml` pins `1.89.0` with `targets = [aarch64-apple-darwin, x86_64-apple-darwin]`; app builds `ARCHS: arm64` only; the ubuntu deps-audit job errors on the missing musl toolchain.
- swift-format: 280 warnings / 38 files — Indentation 117, AddLines 112, LineLength 19, Spacing 12, RemoveLine 9, DoNotUseSemicolons 4, OneVariableDeclarationPerLine 2, UseLetInEveryBoundCaseVariable 1.
- `panes.rs` re-exported from `lib.rs` lines 24-26; no other references in engine/ffi/Swift.
- `solidterm-config` referenced only by root `Cargo.toml:5`, `project.yml:139` (comment), `AGENTS.md:26`, `CLAUDE.md:20`.
- Unreferenced fixtures: `tests/fixtures/claude-md` (14 files), `stream-json` (6), `settings` (19). Referenced by a test: `vttest` (`tests/vttest_corpus.rs`). `font-corpus` is named only in an `engine.rs` comment; `osc-sequences` is read by no test (only `scripts/capture-osc.sh` / `redact-osc.sh` name it).
- DMG 0.4.12 binary mtime 2026-08-17 23:11:14 +0700; commit `502ff17` 23:10:56. Commits after: `7e869e4`, `c3f1276`, `e4fc331`, `a9319c6`, `03f0168` (all `fix:`), `becd135` (docs).
- Test module boundaries (`mod tests` line / total): engine 1931/4885, events 479/1283, osc 506/1030, bridge 922/1160, cells 339/601, search 178/316.
- Swift seams: `TerminalSurfaceView` MARKs at 337, 403, 458, 478, 781, 1404, 1664, 1943, 2015, 2381; `GlyphAtlas` MARKs at 967, 1048, 1305, 1382, 1582, 1849; `MetalRenderer` has one MARK (3144) but clear method clusters (see ticket 14). Private members: 103 / 58 / 53.
- Coverage gaps (no test references): drag-drop, font size bump/drop/reset/reload, overlay encoders for bell / scrollbar / search highlight / cursor, idle-pump behaviour (only the `displayLinkStalled` predicate is tested).
- Existing offscreen Metal readback harnesses: `OverlayPipelineTests.testCursorShapesRenderExpectedGeometry` (~127-200) and `GridCursorReverseVideoTests.renderGrid` (~170-250). `PixelVerifyHelpers` renders SwiftUI views only.
- `MetalRenderer(device:)` is constructible headless in tests (`MetalRendererFontTests`).

- Identity inventory (2026-09-06): `nextterm` appears in 41 files. Prose: `CLAUDE.md:3,30,48`, `AGENTS.md:3,7,36,39`, `README.md:46`, `AppDelegate.swift:267`, `project.yml:93` (+ two pbxproj lines), `engine.rs:2429,3155-3236`. Compat shims: `MetalRenderer.swift:430-433`, `solidterm.{zsh:15-16,bash:20-21,fish:19-22}`. Agents: all six `.claude/agents/*.md` (tracked). Fixtures: six `osc-sequences/*.bin` carry the capture cwd `/Users/USER/Projects/nextterm` in their bytes; prose in `osc-sequences/README.md:3`, `fish-default.meta.json:9`, `zsh-macos-default.meta.json:20`.
- Design vault: `~/Vaults/NextTerm` removed 2026-09-06 (not in Trash); `.gitignore:37-38` names a `~/Vaults/SolidTerm` symlink that never existed; no `vault` symlink in the repo. Vault-era pointers outside files 03/04 delete: 188 lines / 61 files — live-location 21, `ADR-19` 17, `spec/*.md` 132, `decisions/NN` 24, `research/NN` 15; 28 of them in the three files 13-15 split.
- Compat shims protect nothing: no `NextTerm.app` in `/Applications` or `~/Applications`, no rc file sources a nextterm integration, `ShellIntegrationInstaller` overwrites `~/.config/solidterm/shell/*` on every install, no test references either name.
- `app/SolidTerm.xcodeproj/project.pbxproj` regenerates byte-identical from `project.yml` with xcodegen (0 changed lines, 2026-09-06).
- GitHub `ZEN-ZAI/solidterm` is not a GitHub fork (`isFork: false`). No LICENSE file; `CONTRIBUTING.md:78` says UNLICENSED pending a vault decision that no longer exists.
- License facts (2026-09-06): repo is public with no license; all deps permissive (MIT / Apache-2.0 / BSD / ISC / Zlib / Unicode / Unlicense); `alacritty_terminal` Apache-2.0 with `LICENSE-APACHE` only; `GlyphAtlas.swift:1-6` already attributes the LRU algorithm to Alacritty; 121 source files need headers (82 Swift, 21 Rust, 1 Metal, 17 shell); `cargo-deny 0.19.4` installed, `cargo about` not.

## Ticket map

```
01 ci-green ─┬─> 02 swift-format-all ─┬─> 06 metal-offscreen-harness ─> 07 renderer-clock + idle-pump ─> 08 overlay-pixel-tests ─┐
             │                        ├─> 09 font-size + cursor-state tests ──────────────────────────────────────────────────────┼─> 14 split MetalRenderer
             │                        ├─> 10 drag-drop tests ─> 13 split TerminalSurfaceView                                    │
             │                        ├─> 11 boxdrawing-golden ─> 16 restructure BoxDrawing                                     │
             │                        └─> 15 split GlyphAtlas                                                                    │
             ├─> 03 remove panes + config crate                                                                                  │
             ├─> 04 docs cleanup                                                                                                 │
             ├─> 05 tag v0.4.12 + release script + CHANGELOG                                                                     │
             └─> 12 rust move test modules                                                                                       │
                                                                                                                                 └─> 19 retire design-archive citations ─> 20 apply GPL-3.0-or-later ─> 17 smoke + push + merge (human)

03 + 04 + 05 ─> 18 solid identity (runs right after 05, before 06; also a blocker of 19 and 20)
```

Commit order: 01, 02, 03, 04, 05, 18, 06, 07, 08, 09, 10, 11, 12, 13, 14, 15, 16, 19, 20, 17.

## Acceptance (whole effort)

- All CI jobs green on `chore/hygiene-2026-09`: fmt+clippy, Rust test, FFI drift, deps audit, custom lints, Swift test (macos-14 + macos-15).
- `cargo test --workspace` = 288 passed (minus the 15 `panes.rs` tests = 273, plus new tests), `xcodebuild test` ≥ 446 passed, 0 failures.
- `git tag` shows `v0.1.0`, `v0.4.12`.
- `grep -rIil nextterm` (excluding `.git`, `target`, `dist`, `.scratch`) lists exactly the six `tests/fixtures/osc-sequences/*.bin`; `grep -rIEn 'vault/|Vaults/|ADR-19|NEXTTERM|spec/[a-z-]+\.md|decisions/[0-9]|research/[0-9]'` over app / crates / docs / scripts / .github / config files is empty.
- `LICENSE` is the GPL-3.0 text; `scripts/check-license-headers.sh` exits 0 over every tracked source file outside `Generated/`; `THIRD_PARTY_NOTICES.md` equals the generator output and is inside `SolidTerm.app/Contents/Resources/`; both crates report `license = "GPL-3.0-or-later"` in `cargo metadata`.
- Manual smoke on Release build (ticket 17) signed off by the maintainer.

## Assumptions

- `.scratch/` is committed (not gitignored).
- The design vault is gone (removed 2026-09-06, not in Trash); nothing is ported from it — ADRs are written from what the repo enforces.
- Next release after this effort is `0.4.13`, cut by the maintainer with the updated script.
- If a new test exposes a real bug, stop and report; do not fix it inside a hygiene commit.
- Delegation (`/delegate`) is off; all tickets run on Claude in-session.
