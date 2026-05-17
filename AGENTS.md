# SolidTerm — AI Agent Operating Guide

A minimal macOS terminal forked from NextTerm. All Claude-specific features stripped.

## Principles

1. **Stay minimal**. This fork's value is its small surface area. Don't reintroduce Claude integration, agent teams, block model, hooks, or rate-limit UI. If a feature seems "useful for Claude", it doesn't belong here.
2. **Stack A is the architecture**. Swift owns Metal. Rust core is data-only. Don't push CoreText, CALayer, or any Apple type across the FFI.
3. **Atomic commits** — never leave disk in a non-compiling state across tool boundaries.

## Build / test

```bash
cargo check --workspace
cargo test --workspace
cd app
xcodebuild build -scheme SolidTerm -destination 'platform=macOS'
xcodebuild test  -scheme SolidTerm -destination 'platform=macOS'
```

## Renames you should know

- Product name: `SolidTerm`
- Bundle id: `com.zenzai.SolidTerm`
- Source dir: `app/SolidTerm/`
- Internal crates: `solidterm-engine` / `solidterm-config` / `solidterm-ffi`

## Conventions

- Match neighboring style (rustfmt + Swift idioms)
- Zero telemetry — any new outbound network call needs explicit justification
- Cargo features lowercase-kebab
- Rust: prefer `impl` on plain structs over deep trait hierarchies
- Swift: AppKit for chrome, SwiftUI for islands

## Pitfalls (carried over from NextTerm)

- **Never** `find ~/Library/Developer/Xcode/DerivedData/...` to locate a built binary. Use `xcodebuild -showBuildSettings | awk '/BUILT_PRODUCTS_DIR/{print $3}'` instead. Non-deterministic across stale hashes — 30 min triage cost incident on the source project.
- **Optional parameters that fall back to a different meaningful value** are an anti-pattern. Make required or precondition-assert. The original UV-2x-scaling emoji bug (NextTerm v0.1.5 → v0.1.7) hid for 4 versions behind this exact pattern.
