# 06 — Shared Metal offscreen render + readback harness for tests

Status: ready-for-agent
Blocked by: 02
Spec: ../spec.md (D10)

## Goal

One helper that renders into an offscreen `.rgba8Unorm` target, blits to a shared-storage texture, and returns `[UInt8]` plus `pixel(x:y:)` / `assertCellColor` helpers, used by the existing two tests and the new overlay tests (08).

## Steps

1. Add `app/SolidTermTests/MetalOffscreenHarness.swift` extracted from `OverlayPipelineTests.testCursorShapesRenderExpectedGeometry` (~127-200) and `GridCursorReverseVideoTests.renderGrid` (~170-250). API sketch:
   ```swift
   struct MetalOffscreenHarness {
       init(device: MTLDevice, widthPx: Int, heightPx: Int, clear: MTLClearColor) throws
       func render(_ body: (MTLRenderCommandEncoder) throws -> Void) throws -> PixelBuffer
   }
   struct PixelBuffer { let width, height: Int; func rgba(x: Int, y: Int) -> SIMD4<UInt8> }
   ```
2. Refactor the two existing tests to use it; assertions unchanged.
3. Keep `PixelVerifyHelpers` (SwiftUI) as is.

## Verify

`xcodebuild test` — same 446 tests, 0 failures; the two refactored tests still pass in isolation:
`xcodebuild test -only-testing:SolidTermTests/OverlayPipelineTests -only-testing:SolidTermTests/GridCursorReverseVideoTests`.
