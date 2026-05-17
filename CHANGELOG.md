# Changelog

All notable changes to SolidTerm are documented here. The format is based on [Keep a Changelog 1.0.0](https://keepachangelog.com/en/1.0.0/).

## [0.1.0] — 2026-05-17 — fork from NextTerm

Initial fork from `nextterm` v0.1.8 (commit `1633d62`). All Claude-Code-specific features stripped out. The remaining surface is a clean macOS terminal:

### What works
- PTY + VT parsing via alacritty
- Metal renderer (Stack A) with cross-cell shaping for Thai, flag pairs, ZWJ overflow, variation selectors
- Color emoji (Apple Color Emoji) at 2-cell width — fixed UV 2x scaling bug inherited from NextTerm
- IME (Thai + CJK), keyboard input, mouse, drag-drop file paths
- Themes (TOML), font config, theme hot-reload
- Search (regex scrollback)
- Shell integration: OSC 7, OSC 133 (zsh/bash/fish)
- Command palette, look-up popover

### What's stripped (vs NextTerm base)
- Claude Native Core, block model, auth, hooks, agent teams
- Sidebar (rate-limit HUD, hook editor, subagent panel, CLAUDE.md viewer)
- Kitty Graphics Protocol (image attach)
- Block overlay, diff viewer, file-path detector, permission modal
- Most bundled themes; `zenzai` only

### Stats
- 3 Rust crates (was 7), 195 + 13 unit tests pass
- 63 Swift sources (was ~98), 320 XCTest tests pass
- Bundle: `com.zenzai.SolidTerm`, product `SolidTerm`

