# 08 — Pixel tests for all 8 overlay encoders

Status: done — 2026-09-06
Blocked by: 06, 07
Spec: ../spec.md (D10)

## Encoders (MetalRenderer.swift, current lines)

| Encoder | Line | State it reads |
|---|---|---|
| `encodeSelectionOverlay` | 2333 | session selection span |
| `encodeCursorOverlay(state:)` | 2531 | `CursorBlockState?` param, theme cursor colour |
| `encodeImeUnderlineOverlay` | 2694 | composition state |
| `encodeLinkUnderlineOverlay` | 2737 | hovered link span |
| `encodeTextUnderlineOverlay` | 2771 | cells with underline attr |
| `encodeScrollbarOverlay` | 2819 | `lastScrollTop`, `lastScrollTotal`, `gridRows` |
| `encodeBellFlashOverlay` | 2914 | `bellFlashStartTime`, `bellFlashDurationSec`, `bellFlashPeakAlpha`, `now` |
| `encodeSearchHighlightOverlay` | 2946 | `searchHighlights` |

All take `(encoder, drawableSizePx, cellSizePx, gridOriginPx, overlay: OverlayPipeline)` (bell omits cell/grid params).

## Steps

1. Promote the 8 encoders and the state fields above from `private` to `internal` (they move to `MetalRenderer+Overlays.swift` in ticket 14 anyway).
2. New `app/SolidTermTests/OverlayEncoderPixelTests.swift`, one test per encoder, using `MetalOffscreenHarness` (06): small grid (e.g. 8×4 cells, 10×20 px cells), set the state, call the encoder inside `harness.render`, assert:
   - target cell(s) contain the overlay colour (alpha-blended over the clear colour; compare with tolerance ±2/255);
   - a neighbouring cell is exactly the clear colour.
   For bell: `now` at 0 % and 100 % of `bellFlashDurationSec` → visible then fully transparent. For scrollbar: thumb position moves with `lastScrollTop`.
3. Seed state through the narrowest seam: for selection/IME/link/text-underline feed the real session (`paste_chunk`, `start_selection`) or set the internal fields directly if the encoder reads a field.

## Verify

`xcodebuild test -only-testing:SolidTermTests/OverlayEncoderPixelTests` then the full suite; CI on macos-14 and macos-15 must agree (avoid exact-alpha asserts on blended edges).

## Comments

### 2026-09-06 — landed

One commit: `test(app): pin the eight overlay encoders with pixel tests`
(this commit).

Seventeen declarations in `MetalRenderer.swift` lost their `private`: the
eight encoders the table names, plus `lastCursor`, `cells`, `lastScrollTop`,
`lastScrollTotal`, `bellFlashStartTime`, `bellFlashDurationSec`,
`bellFlashPeakAlpha`, `resolvedPalette` and `resolvedSelection`. Nothing else
in the file moved — the diff is seventeen deleted keywords and no other edit.
`app/SolidTermTests/OverlayEncoderPixelTests.swift` is new: eight tests, one
per encoder, each driving the encoder through ticket 06's
`MetalOffscreenHarness` on an 8x4 grid of 10x20 px cells against an 80x80 px
target cleared to a non-grey (64, 26, 13), then reading pixels back.
`project.pbxproj` is the 4-line `xcodegen generate` delta registering the new
file; `Generated/` did not move (the bridge is untouched).

Expected values come from outside the code under test: geometry as explicit
pixel coordinates derived from the bands the MSL `overlay_fragment` documents
(left 12 % for the beam, bottom 15 % for kinds 3/4, bottom 8 % for kind 5),
alphas as pinned literals (selection 0.55, search 0.55 active / 0.25 inactive,
bell peak 0.25), and the composite recomputed from `OverlayPipeline`'s
declared blend state rather than from any Swift the encoders run. Bell is
sampled at 0 % and at 100 % of `bellFlashDurationSec`; the scrollbar thumb is
asserted at both ends of `lastScrollTop`, and absent when `lastScrollTotal`
is 0.

Judgement calls:

- **The line numbers in the table above are stale.** Tickets 06 and 07 shifted
  the file: the encoders sit at 2374 / 2573 / 2737 / 2780 / 2814 / 2862 /
  2958 / 2990, not 2333 / 2531 / 2694 / 2737 / 2771 / 2819 / 2914 / 2946. All
  eight were located and promoted by name, and every name in the table exists
  exactly once.
- **`resolvedPalette` and `resolvedSelection` were promoted too**, beyond the
  names in the "State it reads" column. The selection and text-underline
  asserts read the renderer's own resolved colour rather than re-deriving a
  theme constant, so a theme left behind by another test cannot silently make
  them pass. Both must be internal for ticket 14's split regardless.
- **`bellFlashPeakAlpha` is promoted although no test reads it.** The table
  names it, so it is in scope; the bell test still pins 0.25 as a literal
  precisely so the assertion can disagree with the constant instead of
  restating it.
- **The table's "theme cursor colour" for `encodeCursorOverlay` does not match
  the tree.** That encoder reads `state.color` from its `CursorBlockState?`
  parameter; `resolvedCursor` is read by `computeCursorBlockState`, which
  ticket 09 owns. `resolvedCursor` therefore stayed private, and the cursor
  test supplies its own colour.
- **`resizeGrid(cols:rows:)` is the grid seam.** Sizing the renderer through
  the production path keeps `gridCols` / `gridRows` `private(set)` — the
  narrowest seam step 3 asks for, and one fewer setter opened than D9 would
  otherwise need.
- The IME test drives a real `TerminalSurfaceView.setMarkedText`, and the
  selection test a real `/bin/cat` session through `attachSessionForTesting`;
  the remaining encoders read fields, which the tests set directly.

Review (fixed point `b8343e1`, standards + spec axes) found no missed
requirement and no wrong behaviour. Two findings were taken. The neighbour
assert had been running at the same ±2 tolerance as the painted one, which
would have accepted a 2/255 bleed onto a cell this ticket says is "exactly the
clear colour" — the ±2 belongs to blended edges, and nothing blended there, so
`assertClear` now compares at 0. And the cursor test had pinned
`Theme.Color.cursorDefaultLinear`, which is also the renderer's own default
cursor colour, so the assertion could not have told a substituted default from
an honoured `state.color`; it now passes a synthetic colour. Rejected as
things the ticket forbids: hoisting the `/bin/cat` fixture shared with
`SelectionInputTests` and `CopyPasteTests` into a common helper (a refactor
that grows the diff), and swapping the fixture's force-unwrap for `XCTUnwrap`
(the neighbouring tests' convention).

Gates before the commit: `cargo test --workspace -j 8` → 273 passed, 0 failed;
the ticket's Verify target
(`-only-testing:SolidTermTests/OverlayEncoderPixelTests`) → `** TEST
SUCCEEDED **`, Executed 8 tests, 0 failures. Also green: `cargo fmt --all
--check`, `cargo clippy --workspace --all-targets` under `-D warnings`,
`scripts/check-ffi-drift.sh`, the three lint scripts, and the CI
`swift-format lint --strict` sweep over every source outside `Generated/`.

The full Swift suite ran clean once at Executed 457 tests, 2 skipped, 0
failures. Three later full runs each reported 2 failures, both assertions of
the single known-flaky `CopyPasteTests/testPasteConsultsBracketedPasteFlag`
(PTY echo timing, the documented load flake); rerun alone it passed in 0.856 s.
No other test failed in any run. The other lane was building throughout, which
is the documented load condition.
