# Changelog

All notable changes to SolidTerm are documented here. The format is based on [Keep a Changelog 1.0.0](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Fixed
- Everything running in a pane could freeze for as long as the display stayed asleep (a 7.6 h stall of a long-running CLI overnight), then resume the instant the screen came back. Root cause: `poll_output` — the only drain of the bounded PTY reader channel — was reached solely from `draw(update:)`, and macOS stops the `CAMetalDisplayLink` when the display sleeps or the window is fully occluded. The channel filled, the reader thread parked in `send`, the PTY master buffer backed up, and the child blocked in `write()`. A watchdog now drains the engine whenever the link stops ticking, and repaints from a full-frame delta once it resumes.
- Ctrl-C (and the whole Ctrl-A..Z / Ctrl-[ \ ] ^ _ / Ctrl-Space control family) could suddenly stop reaching the foreground program — most visibly, Ctrl-C no longer interrupting a full-screen TUI like Claude. Root cause: an IME composition left orphaned when a ⌘C/⌘V fired mid-preedit kept `hasMarkedText()` permanently true, wedging the keyboard direct-send gate. Control-mapped keys now bypass the IME gate (they're never composition input) and any active composition is cancelled by Copy/Paste/Paste-Plain/Select-All.

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

