# SolidTerm

A minimal, fast, native macOS terminal emulator. Built on Swift + Rust with Metal rendering and `alacritty_terminal` for VT parsing.

**Status**: pre-1.0 development.

## Build from source

Requirements: Xcode 16+, Rust 1.80+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
cd app
xcodebuild build -scheme SolidTerm -destination 'platform=macOS'
xcodebuild test  -scheme SolidTerm -destination 'platform=macOS'

# Open and run
open ~/Library/Developer/Xcode/DerivedData/SolidTerm-*/Build/Products/Debug/SolidTerm.app
```

## What you get

- Fast Metal renderer (avg ≤ 1 ms CPU encode per frame, p99 < 2 ms)
- Cross-cell grapheme shaping: Thai (`ทำ`, `ก่อ`), regional indicator flags (`🇹🇭`), ZWJ family overflow, variation selectors
- Full color emoji (Apple Color Emoji) at 2-cell width
- IME: Thai, CJK
- Drag-and-drop file paths (shell-quoted)
- Selection + clipboard (OSC 52)
- Themes (TOML, hot-reload)
- Shell integration: OSC 7 cwd, OSC 133 prompt markers (zsh/bash/fish)
- Search (regex scrollback)
- Look-up popover

## Architecture

- Swift host owns Metal rendering, AppKit chrome, SwiftUI islands
- Rust core (`solidterm-engine`) wraps `alacritty_terminal` for PTY + VT
- `swift-bridge` FFI carries pure data across the boundary
- See `CLAUDE.md` for the engineering memory

## Built on

- [`alacritty_terminal`](https://github.com/alacritty/alacritty) — PTY + VT engine
- [`swift-bridge`](https://github.com/chinedufn/swift-bridge) — Rust ↔ Swift FFI
- CoreText + Apple Color Emoji — glyph shaping and rasterization

## License

GPL-3.0-or-later — see `LICENSE`.
