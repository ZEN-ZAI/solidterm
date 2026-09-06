# 09 — Tests for font-size methods and computeCursorBlockState

Status: ready-for-agent
Blocked by: 02
Spec: ../spec.md (D10)

## Steps

1. `app/SolidTermTests/MetalRendererFontSizeTests.swift` (headless `MetalRenderer(device:)`, pattern from `MetalRendererFontTests`):
   - `bumpFontSize` (716) / `dropFontSize` (725) move the effective point size by the configured step and clamp at min/max;
   - `resetFontSize` (737) returns to `FontSettings` default;
   - `reloadFont` (756) marks the atlas dirty and recomputes cell size (`GlyphAtlas` cell-size derivation);
   - observe through existing public/internal state (`atlasDirty`, cell size) — promote to `internal private(set)` where needed.
2. `app/SolidTermTests/CursorBlockStateTests.swift` for `computeCursorBlockState` (2452): visible/hidden, focused/unfocused, blink phase via injected `now` (07), alt-screen, cursor shape mapping (`cursorKind` 2984). Promote to `internal` (static or instance as it is).

## Verify

`xcodebuild test -only-testing:SolidTermTests/MetalRendererFontSizeTests -only-testing:SolidTermTests/CursorBlockStateTests` then the full suite.
