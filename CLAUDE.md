# SolidTerm — Project Memory for Claude Code

A native macOS terminal emulator. Minimal, fast, solid. Forked from NextTerm with all Claude-Code-specific integration stripped — pure terminal only.

## Architecture (committed)

- **Language**: Swift (UI/host) + Rust (core engine)
- **FFI**: `swift-bridge` — pure data across the boundary (no Metal types)
- **Stack A**: Swift owns all Metal code; Rust core is data-only
- **Terminal engine**: `alacritty_terminal` 0.26+ wrapped in `solidterm-engine`
- **Min macOS**: 14 (Sonoma)

## Repo layout

```
solidterm/
├── Cargo.toml             ← workspace root (3 crates)
├── crates/
│   ├── solidterm-engine/   ← alacritty_terminal wrapper + OSC routing
│   ├── solidterm-config/   ← config + settings.json
│   └── solidterm-ffi/      ← swift-bridge surface (only crate Swift links)
├── app/
│   ├── SolidTerm/         ← Swift sources
│   ├── SolidTermTests/    ← XCTest
│   └── project.yml        ← xcodegen spec
└── CLAUDE.md              ← this file
```


## What's IN this fork

Core terminal features only:

- PTY + VT parsing via alacritty
- Metal renderer (Stack A): GlyphAtlas + GridPipeline + OverlayPipeline
- Cross-cell grapheme shaping: Thai SARA AM, regional indicator flag pairs, ZWJ overflow, variation selectors
- Color emoji (Apple Color Emoji) with dual gray+color atlas
- Input handling: keyboard, mouse, IME (Thai + CJK), Kitty keyboard protocol
- Drag-and-drop: file paths as shell-quoted arguments
- Selection + clipboard (OSC 52)
- Themes (TOML), font config, theme hot-reload
- Window/tab/pane chrome (basic split-pane via alacritty's tree)
- Search (regex scrollback)
- Shell integration: OSC 7 cwd, OSC 133 prompt markers (zsh/bash/fish)
- Command palette
- Look-up popover

## What's NOT in this fork

Stripped from the NextTerm base:

- Claude Native Core (stream-JSON parser, QueryFSM)
- Claude block model + block state machine
- Auth (Claude credential cascade + Keychain)
- Hook runner + hook editor UI
- Agent-team mode (split-pane Claude orchestration)
- Sidebar (rate-limit HUD, hook editor, subagent panel, CLAUDE.md viewer)
- Kitty Graphics Protocol (image → Claude CLI)
- Block overlay (NSHostingView blocks, Claude block chrome)
- Diff viewer, file-path detector, permission modal

If a Claude feature comes up: out of scope for SolidTerm.

## Build commands

```bash
cargo check --workspace
cargo test --workspace
cd app
xcodebuild build -scheme SolidTerm -destination 'platform=macOS'
xcodebuild test  -scheme SolidTerm -destination 'platform=macOS'
```

## Pitfall

Pin the build path via `xcodebuild -showBuildSettings | awk '/BUILT_PRODUCTS_DIR/{print $3}'` — never `find` DerivedData (non-deterministic across stale hashes).

## Agent skills

### Issue tracker

Issues and specs live as local markdown under `.scratch/<feature-slug>/` in this repo (no GitHub Issues). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`, recorded as a `Status:` line in each issue file. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root (created lazily by `/domain-modeling`). See `docs/agents/domain.md`.
