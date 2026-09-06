# 09 — Tests for font-size methods and computeCursorBlockState

Status: done — 2026-09-06
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

## Comments

### 2026-09-06 — landed

One commit: `test(app): cover font-size steps and the cursor block state`
(this commit). `app/SolidTermTests/MetalRendererFontSizeTests.swift` (6 tests)
and `app/SolidTermTests/CursorBlockStateTests.swift` (9 tests), plus the
xcodegen regen that puts them in the target.

Four declarations in `MetalRenderer.swift` lost their `private`, per D9:
`computeCursorBlockState()` itself, `resolvedCursor` (the colour test drives a
synthetic value, so the assertion can distinguish an honoured colour from the
default — the lesson ticket 08's review left), and `blinkPeriodSec` /
`blinkPauseAfterKeystrokeSec` (the phase samples are fractions of the
constants rather than restatements of 0.9 and 0.5). Step 1's "promote to
`internal private(set)`" could not apply to `resolvedCursor`, which the test
writes. Everything else the tests read was already internal after 07 and 08.

Where the ticket and the tree disagree, the tree won and the deviation is
named here:

- Step 2 asks for **focused/unfocused** and **alt-screen** cases.
  `computeCursorBlockState` has neither branch. It gates on four things —
  `lastCursor == nil`, `cursor.hidden`, `lastScrollTop > 0`, an off-grid
  row/col — and then on the blink alpha. The renderer holds no focus state at
  all, and the alt screen reaches the cursor only as an ordinary cursor
  payload. So the tests cover the gates that exist, including the two the
  ticket did not list, and no focus or alt-screen test was invented.
- Step 1 says `reloadFont` "marks the atlas dirty". It is the other way round:
  the callers raise `atlasDirty` and `reloadFont` lowers it on all three exits.
  The tests assert the tree. `reloadFont` lowering the flag on its no-window
  failure path is consistent with `windowChanged` lowering it before building
  the atlas itself, so it was judged deliberate and left alone.
- There is no configured step constant: the ±1 is a literal in both
  `MetalRenderer` and `FontSettings`, so the tests assert one point per press.
- `resetFontSize` clears the override rather than writing the default size, so
  the window follows the global picker. The test proves the difference by
  moving the global afterwards.

The cell-metric tests install a real offscreen `NSWindow` through
`windowChanged(window:)`, because `reloadFont` needs a backing scale. With no
`CAMetalLayer` attached that call returns right after capturing the window, so
no display link, idle pump or engine session starts. `hostWindow` is `weak`,
so the test class holds the strong reference.

Review (fixed point `84e940b`, standards + spec axes) found no missed
requirement and no wrong behaviour. Four findings were taken, all inside the
new files. Two `atlasDirty` assertions could not have failed —
`windowChanged` had just lowered the flag in one, and the other restated the
declared default — so the first was dropped and the second now raises the flag
through ⌘+ before checking that the failing rebuild lowers it. Two comments
misdescribed the code they introduce: the header claimed the size methods
"only move `fontSizeOverride`" (they also clamp, early-return and raise the
dirty flag — that early return is what makes saturation stop), and the
keystroke test read as though `recordKeystroke(eventTimestamp:)` set the pause
window from its argument, when it stamps `now()`. Rejected as things the
ticket forbids: hoisting the two `makeRenderer` helpers into a shared fixture
(a refactor that grows the diff).

Gates before the commit: `cargo test --workspace -j 8` → 273 passed, 0 failed;
the ticket's Verify target → `** TEST SUCCEEDED **`, Executed 15 tests, 0
failures; the full Swift suite → `** TEST SUCCEEDED **`, Executed 472 tests, 2
skipped, 0 failures (457 before this ticket). Also green: `cargo fmt --all
--check`, `cargo clippy --workspace --all-targets` under `-D warnings`,
`scripts/check-ffi-drift.sh`, the three lint scripts, and the CI
`swift-format lint --strict` sweep over every source outside `Generated/`.
An earlier full Swift run reported 2 failures, both assertions of the known
flaky `CopyPasteTests/testPasteConsultsBracketedPasteFlag`; rerun alone it
passed, and the final run was clean. `app/SolidTerm/Generated/` was unchanged
by the builds — the bridge is untouched.

Not done here: the `MetalRenderer.swift` split, which ticket 14 owns.
