// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// The Stage 2 overlay pass — confirms
// the unified overlay pipeline constructs against the bundled
// `default.metallib`, that the cursor color matches the
// `cursor-default` design token, and that the renderer's cursor
// shape-mapping + blink-phase logic match the M1 4.7 contract.
//
// Pixel correctness for each cursor shape (block / beam / underline)
// is validated visually in the running app and pinned in the commit
// body via `screencapture` + `NSBitmapImageRep.colorAt` samples.

import Metal
import XCTest

@testable import SolidTerm

final class OverlayPipelineTests: XCTestCase {

    private var device: MTLDevice!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    }

    override func tearDown() {
        device = nil
    }

    /// Constructible smoke test — pipeline state is non-nil and no
    /// throws come out of either function lookup or
    /// `makeRenderPipelineState`.
    func testOverlayPipelineConstructible() throws {
        let pipeline = try OverlayPipeline(device: device, pixelFormat: .bgra8Unorm_srgb)
        XCTAssertNotNil(pipeline.pipelineState)
    }

    /// Pin the cursor color to matcha `#c4919f`. Regression guard
    /// for typo'd palette values.
    func testThemeCursorColorMatchesSpec() {
        let cursor = Theme.Color.cursorDefaultLinear
        let r = SRGBLinearLUT.referenceLinear(forByte: 0xc4)
        let g = SRGBLinearLUT.referenceLinear(forByte: 0x91)
        let b = SRGBLinearLUT.referenceLinear(forByte: 0x9f)
        XCTAssertEqual(cursor.x, r, accuracy: 1e-5)
        XCTAssertEqual(cursor.y, g, accuracy: 1e-5)
        XCTAssertEqual(cursor.z, b, accuracy: 1e-5)
        XCTAssertEqual(cursor.w, 1.0, accuracy: 1e-5)
    }

    /// Pin the `CURSOR_SHAPE_*` u8 → `OverlayKind` mapping. The constants
    /// live in `crates/solidterm-ffi/src/bridge.rs:101-104`; this test
    /// fails loudly if either side drifts.
    func testShapeKindMapping() {
        XCTAssertEqual(MetalRenderer.cursorKind(forShape: 0), .cursorBlock)
        XCTAssertEqual(MetalRenderer.cursorKind(forShape: 1), .cursorBeam)
        XCTAssertEqual(MetalRenderer.cursorKind(forShape: 2), .cursorUnderline)
        // Unknown shapes fall back to block — defensive against a
        // misbehaving producer.
        XCTAssertEqual(MetalRenderer.cursorKind(forShape: 3), .cursorBlock)
        XCTAssertEqual(MetalRenderer.cursorKind(forShape: 0xff), .cursorBlock)
    }

    /// Cursor blink alpha cycles 1.0 → 0.0 → 1.0 over a 2 × period
    /// span, with the visible half coming first. The period is 500 ms
    /// by default; tests pin the
    /// shape against any period so future configurability doesn't break
    /// the contract.
    func testBlinkAlphaTogglesAtPeriodBoundaries() {
        let period: CFTimeInterval = 0.5
        // First half-period: fully visible.
        XCTAssertEqual(blinkAlpha(elapsed: 0.0, period: period), 1.0)
        XCTAssertEqual(blinkAlpha(elapsed: 0.25, period: period), 1.0)
        XCTAssertEqual(blinkAlpha(elapsed: 0.49, period: period), 1.0)
        // Second half-period: hidden.
        XCTAssertEqual(blinkAlpha(elapsed: 0.51, period: period), 0.0)
        XCTAssertEqual(blinkAlpha(elapsed: 0.75, period: period), 0.0)
        XCTAssertEqual(blinkAlpha(elapsed: 0.99, period: period), 0.0)
        // Wraps cleanly into the next cycle.
        XCTAssertEqual(blinkAlpha(elapsed: 1.01, period: period), 1.0)
        XCTAssertEqual(blinkAlpha(elapsed: 1.51, period: period), 0.0)
    }

    /// `period <= 0` short-circuits to "always visible" so steady
    /// (non-blinking) cursors don't accidentally drop frames.
    func testBlinkAlphaSteadyCursorAlwaysVisible() {
        XCTAssertEqual(blinkAlpha(elapsed: 0.0, period: 0.0), 1.0)
        XCTAssertEqual(blinkAlpha(elapsed: 99.99, period: 0.0), 1.0)
        XCTAssertEqual(blinkAlpha(elapsed: 0.5, period: -1.0), 1.0)
    }

    /// `OverlayUniforms` MUST stay layout-compatible with the MSL
    /// `OverlayUniforms` struct in `Shaders.metal`. Field-by-field
    /// matching is verified by Metal pipeline construction; this guard
    /// catches accidental field reordering on the Swift side that
    /// `setVertexBytes` would still accept.
    ///
    /// Layout (matches MSL — both use std140-equivalent rules):
    ///   offset  field          size  align
    ///        0  screenSizePx      8      8  (float2)
    ///        8  cellOriginPx      8      8
    ///       16  cellSizePx        8      8
    ///       24  (pad to 32)
    ///       32  colorLinear      16     16  (float4)
    ///       48  kind              4      4
    ///       52  alpha             4      4
    ///       56  cellSpanCols      4      4   (4.5: multi-cell quad span)
    ///       60  (pad to stride)
    ///       64  stride (rounded to alignment 16)
    func testOverlayUniformsLayoutPinned() {
        XCTAssertEqual(MemoryLayout<OverlayUniforms>.size, 60)
        XCTAssertEqual(MemoryLayout<OverlayUniforms>.stride, 64)
        XCTAssertEqual(MemoryLayout<OverlayUniforms>.alignment, 16)
    }

    /// Render each cursor shape into a small offscreen target and
    /// read back pixels to confirm the shader emits cursor-color
    /// geometry where expected. Substitutes for the brief's
    /// "screencap + sample pixels" gate when the agent shell lacks
    /// macOS Screen Recording permission (window-region captures get
    /// redacted to a placeholder color, defeating live-window
    /// sampling). Pixel-level signal is preserved — we sample the
    /// actual MSL output, just into a render target we own rather
    /// than the system framebuffer.
    ///
    /// Layout: 16-px cell at origin (0, 0) in a 32×32 target. Cursor
    /// color expected linear → blit unchanged through .rgba8Unorm
    /// readback (no sRGB encode-on-store path).
    func testCursorShapesRenderExpectedGeometry() throws {
        let pipeline = try OverlayPipeline(device: device, pixelFormat: .rgba8Unorm)
        let harness = try MetalOffscreenHarness(
            device: device, widthPx: 32, heightPx: 32,
            clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))

        // Render one cursor shape and return the readback pixel buffer.
        func render(kind: OverlayKind) throws -> PixelBuffer {
            // Cell at origin (0, 0), 16×16 px. Cursor uniform alpha=1
            // and color is pure (1, 0, 1, 1) so we can detect cursor
            // pixels via the magenta R+B channels — distinct from both
            // the black clear (0, 0, 0) and `accent-running` #7aa2f7 (which
            // also has R+B but mid-G; we want unambiguous hits here).
            let uniforms = OverlayUniforms(
                screenSizePx: SIMD2<Float>(32, 32),
                cellOriginPx: SIMD2<Float>(0, 0),
                cellSizePx: SIMD2<Float>(16, 16),
                colorLinear: SIMD4<Float>(1, 0, 1, 1),
                kind: kind.rawValue,
                alpha: 1.0,
                cellSpanCols: 1)
            return try harness.render { encoder in
                pipeline.encode(uniforms: uniforms, encoder: encoder)
            }
        }

        // Magenta cursor pixel: high R, low G, high B. The bands are not
        // symmetric around a single tolerance, so this one stays local
        // rather than going through `PixelBuffer.matchesColor`.
        @inline(__always) func isCursor(_ pixels: PixelBuffer, x: Int, y: Int) -> Bool {
            let p = pixels.rgba(x: x, y: y)
            return p.x > 200 && p.y < 50 && p.z > 200
        }
        // The clear colour, for the "stays background" samples below.
        let clear = SIMD3<UInt8>(0, 0, 0)

        // — Block: full 16×16 cell painted cursor color.
        let block = try render(kind: .cursorBlock)
        XCTAssertTrue(isCursor(block, x: 0, y: 0), "block: top-left cell corner")
        XCTAssertTrue(isCursor(block, x: 8, y: 8), "block: cell center")
        XCTAssertTrue(isCursor(block, x: 15, y: 15), "block: bottom-right cell corner")
        block.assertCellColor(
            x: 16, y: 8, clear, tolerance: 19, "block: outside cell stays clear")
        block.assertCellColor(
            x: 24, y: 24, clear, tolerance: 19, "block: far outside cell stays clear")

        // — Beam: only left ~12% (~2px at 16px width) painted.
        let beam = try render(kind: .cursorBeam)
        XCTAssertTrue(isCursor(beam, x: 0, y: 8), "beam: cell-left")
        XCTAssertTrue(isCursor(beam, x: 1, y: 8), "beam: cell-left+1")
        beam.assertCellColor(x: 4, y: 8, clear, tolerance: 19, "beam: cell-mid is bg")
        beam.assertCellColor(x: 8, y: 8, clear, tolerance: 19, "beam: cell-center is bg")
        beam.assertCellColor(x: 14, y: 8, clear, tolerance: 19, "beam: cell-right is bg")

        // — Underline: only bottom ~15% (~3px at 16px height) painted.
        let underline = try render(kind: .cursorUnderline)
        underline.assertCellColor(x: 8, y: 0, clear, tolerance: 19, "underline: cell-top is bg")
        underline.assertCellColor(x: 8, y: 8, clear, tolerance: 19, "underline: cell-mid is bg")
        underline.assertCellColor(
            x: 8, y: 12, clear, tolerance: 19, "underline: cell-just-above-bottom-band")
        XCTAssertTrue(isCursor(underline, x: 8, y: 14), "underline: bottom band")
        XCTAssertTrue(isCursor(underline, x: 8, y: 15), "underline: cell-bottom row")
    }

    /// Encode-doesn't-throw smoke test — drives the full pipeline path
    /// (set state, set bytes, drawPrimitives) against an offscreen
    /// target. Mirrors `CellPipelineTests.testEncodeDoesNotRaise` so
    /// any future Metal-validation regression on the overlay path
    /// surfaces in CI rather than only on a live window.
    func testEncodeDoesNotRaise() throws {
        let pipeline = try OverlayPipeline(device: device, pixelFormat: .bgra8Unorm_srgb)
        let queue = try XCTUnwrap(device.makeCommandQueue())

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: 256, height: 128, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: texDesc))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        let uniforms = OverlayUniforms(
            screenSizePx: SIMD2<Float>(256, 128),
            cellOriginPx: SIMD2<Float>(16, 16),
            cellSizePx: SIMD2<Float>(8, 16),
            colorLinear: Theme.Color.cursorDefaultLinear,
            kind: OverlayKind.cursorBlock.rawValue,
            alpha: 1.0,
            cellSpanCols: 1)
        pipeline.encode(uniforms: uniforms, encoder: encoder)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        XCTAssertNil(buffer.error, "expected overlay encode to complete cleanly")
    }
}
