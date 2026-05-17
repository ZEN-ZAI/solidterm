# Phase 0 Day 3-4 — kickoff prompt

Drop the section below into a fresh Claude Code session started from `~/Projects/solidterm/` to resume the Metal-spike work with full context.

---

I'm continuing work on **SolidTerm**, a macOS terminal with native Claude Code integration. Phase 0 Day 1 is shipped (11 atomic commits on `main`); now I'm starting **Phase 0 Day 3-4 — Xcode project scaffold + Metal spike**.

## Where things live

- **Repo**: `~/Projects/solidterm/` (you're here). 11 commits, working tree clean.
- **Vault** (architecture, decisions, specs, research): `/Users/zen/Vaults/SolidTerm/` — read-only canonical source.

## Required reading (in this order)

1. `AGENTS.md` (repo root) — operating conventions, stop-the-line rules, Stack A boundary.
2. `CLAUDE.md` (repo root) — project orientation, build commands, what to ignore.
3. `/Users/zen/Vaults/SolidTerm/decisions/05-renderer.md` — Stack A commitment (**Swift owns ALL Metal**).
4. `/Users/zen/Vaults/SolidTerm/spec/swift-app-modules.md` — module layout, `MTKView`/`CAMetalLayer` host, IME ownership.
5. `/Users/zen/Vaults/SolidTerm/spec/metal-renderer.md` — pipeline stages, atlas, frame pacing.
6. `/Users/zen/Vaults/SolidTerm/spec/m1-task-breakdown.md` §Week 3 — the concrete tasks 3.1–3.11 we're executing today.
7. `/Users/zen/Vaults/SolidTerm/research/12-rendering-de-risk-synthesis.md` — kill criterion + Plan B.

Don't skip these. Spec authority is real: code that diverges silently from spec is a stop-the-line per AGENTS.md rule 6.

## Environment

Xcode 16.4 is installed at a non-default path. Either of these works:

```bash
# Option A — per-session export (no sudo needed)
export DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer

# Option B — make permanent (one-time, requires sudo)
sudo xcode-select -s /Applications/Xcode-16.4.0.app/Contents/Developer
```

Verify before any Xcode-touching command:
```bash
xcrun --find xcodebuild   # should resolve to the path above
```

Rust toolchain is pinned to 1.89.0 via `rust-toolchain.toml`. `cargo check --workspace` should be green from a clean checkout.

## Goal

Ship Phase 0 Day 3-4 = **Stack A go/no-go gate**.

End state to reach:
1. `app/SolidTerm.xcodeproj` — Xcode project with App + Tests targets.
2. `cargo` build phase wired into Xcode so swift-bridge regenerates Swift shims on every build.
3. `MTKView` host with `CAMetalLayer` attached.
4. Glyph atlas built from CoreText (~10 ASCII glyphs is plenty for the spike).
5. One MSL pipeline + uniforms; render the letter "A" at the cursor cell.
6. Drive frame pacing with `CAMetalDisplayLink` at 120 Hz.
7. Measure **typing-to-pixel latency** via `CAMetalDisplayLink.targetTimestamp` minus `NSEvent` keyUp time.
8. Print the p50 + p99 over 1,000 keystrokes.

## Exit criteria (any one fails ⇒ not done)

- `xcodebuild test -scheme SolidTerm -destination 'platform=macOS'` green.
- `cargo check --workspace` + `cargo test --workspace` still green.
- Glyph renders cleanly: no flicker, no artifacts, fills the cell, anti-aliased.
- Typing-to-pixel **p99 ≤ 10 ms** on this Mac (target is 8 ms; 10 ms gives perf budget headroom).
- All commits are atomic conventional commits (`<type>(<scope>): <subject>`).
- Pre-commit hook passes every commit — **never `--no-verify`**.

## Kill criterion (pivot to Plan B)

Per `research/12-rendering-de-risk-synthesis.md`: if typing-to-pixel **> 20 ms p99 after 2 days** of investigation and the cause isn't a fixable bug, pivot to Plan B (Alacritty's OpenGL backend + Swift sidecar compositor). Don't grind past the 2-day bound.

## Hard rails (Stack A)

- Swift owns **every** line of Metal code. No `metal-rs`, no `objc2-metal`, no wgpu in Rust.
- Rust core stays data-only across the FFI: `FrameDelta` / `BlockDelta` / damage rows. The current `solidterm-ffi/src/bridge.rs` round-trip stub (`ffi_greet`) works — extend it, don't replace it.
- No outbound network endpoints (per `decisions/03-telemetry.md`). Pre-commit hook will block obvious analytics SDKs.
- `unsafe` block must carry a `// SAFETY:` comment; pre-commit warns.

## Subagents available

`.claude/agents/` has 6 specialists. Use them:
- `@swift-metal-expert` — Swift / Metal / CoreText / `NSTextInputClient` / AppKit work (this is most of today's work).
- `@rust-expert` — for any Rust-side FFI type or scaffolding changes.
- `@code-reviewer` — invoke on every diff before merging to `main`.
- `@security-reviewer` — when you touch FFI or anything in `.github/CODEOWNERS`.
- `@test-writer` — proactively after each task lands.
- `@spec-keeper` — to update Status lines on specs as code arrives.

The `@swift-metal-expert` definition itself sets `isolation: worktree`, so big refactors on its watch are isolated.

## Workflow rules (from AGENTS.md)

- Trunk-based: commit to `main` for changes < 30 min / < 300 LoC. Branch only for speculative work.
- Atomic conventional commits. AI drafts commit messages; human edits the first line and the *why*.
- After substantive change → invoke `@code-reviewer` on the diff in a fresh context.
- Match neighboring style. No drive-by refactors.

## First actions (do these now, in this order)

```bash
# 1. Confirm environment
export DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer
xcrun --find xcodebuild
cd ~/Projects/solidterm
git log --oneline | head -5
cargo check --workspace

# 2. Read the docs listed under "Required reading"

# 3. Open the M1 task breakdown to find today's work
$EDITOR /Users/zen/Vaults/SolidTerm/spec/m1-task-breakdown.md   # §Week 3 — tasks 3.1–3.11
```

After reading, propose a concrete task plan for today (which of 3.1–3.11 you'll do, in what order, with rough estimates) **before** writing any code. Then start with task 3.1 (Xcode scaffold).

## What I want from you

1. Confirm you've loaded the required reading (one-line acknowledgement).
2. Propose the day's plan (numbered list, ~10 items max).
3. Wait for my OK before opening Xcode or writing code.
4. After each task lands: open a small commit, invoke `@code-reviewer`, move on.

Keep updates short. A clear sentence is better than a paragraph.
