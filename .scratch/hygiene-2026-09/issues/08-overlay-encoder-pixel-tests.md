# 08 — Pixel tests for all 8 overlay encoders

Status: ready-for-agent
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
