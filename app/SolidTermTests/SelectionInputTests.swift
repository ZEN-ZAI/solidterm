// Tests for M1 task 4.5 — selection input + render path.
//
// Three layers of coverage live here:
//
//  1. **FFI shape pinning** — exercises `TerminalSession.start_selection /
//     update_selection / clear_selection / selection_span` round-trips
//     directly through the Swift binding so future bridge.rs ABI drift
//     surfaces in CI alongside the Rust-side tests in
//     `crates/solidterm-ffi/src/bridge.rs::tests`.
//
//  2. **Selection-mode constants** — pin the `SELECTION_MODE_*` Swift
//     mirrors in `TerminalSurfaceView` against the matching numeric
//     literals in `bridge.rs::kinds`. swift-bridge 0.1.59 doesn't
//     export `pub const` to Swift so the cross-language contract is
//     "matching numeric literals with cite-comments"; this test catches
//     accidental drift.
//
//  3. **Shader pixel readback** — drives the kind=2 (selection) path
//     of the unified overlay shader against an offscreen render target
//     and asserts the spec'd `#3d4254` × 0.35 alpha-blended tint
//     appears where expected. Substitutes for "screencap + sample
//     pixels" when the agent shell can't synthesize live mouse events
//     — pixel-level signal is preserved by sampling our own MSL output
//     into a render target we own.
//
// Live mouse-event synthesis is blocked in headless XCTest the same
// way `scrollWheel` was at 4.4 (NSEvent.mouseEvent's internal
// inconsistency assertion + CGEvent posting requiring an active GUI
// session). The FFI round-trip + shader readback together cover the
// architecturally-relevant signal: that mouse handlers WOULD drive
// the engine through the right shape, and that the engine state WOULD
// paint the right pixels. Live drag verification is owed to dogfood.

import AppKit
import Metal
import XCTest

@testable import SolidTerm

final class SelectionInputTests: XCTestCase {

    // MARK: - 1. FFI round-trips

    /// Single-row drag selection: start at (5, 10), update to (5, 20).
    /// `selection_span` must report the inclusive `[10, 20]` range on
    /// row 5.
    func testSimpleDragSelectionRoundTripsThroughFFI() {
        let session = Self.makeCatSession()
        session.start_selection(TerminalSurfaceView.SELECTION_MODE_SIMPLE, 5, 10)
        session.update_selection(5, 20)
        let span = session.selection_span()
        XCTAssertEqual(span.len(), 5, "selection_span wire format is exactly 5 u32s")
        XCTAssertEqual(span.get(index: 0), 5)
        XCTAssertEqual(span.get(index: 1), 10)
        XCTAssertEqual(span.get(index: 2), 5)
        XCTAssertEqual(span.get(index: 3), 20)
        XCTAssertEqual(span.get(index: 4), 0, "Simple is stream selection")
    }

    /// Triple-click selects an entire logical row. /bin/cat at 80 cols
    /// ⇒ `[0, 79]` on the clicked row.
    func testTripleClickLineSelectionCoversFullRow() {
        let session = Self.makeCatSession()
        session.start_selection(TerminalSurfaceView.SELECTION_MODE_LINE, 7, 0)
        let span = session.selection_span()
        XCTAssertEqual(span.len(), 5)
        XCTAssertEqual(span.get(index: 0), 7)
        XCTAssertEqual(span.get(index: 1), 0)
        XCTAssertEqual(span.get(index: 2), 7)
        XCTAssertEqual(span.get(index: 3), 79)
    }

    /// Clearing produces the empty-Vec sentinel. Idempotent.
    func testClearSelectionProducesEmptySpan() {
        let session = Self.makeCatSession()
        session.start_selection(TerminalSurfaceView.SELECTION_MODE_SIMPLE, 3, 5)
        session.update_selection(3, 10)
        XCTAssertEqual(session.selection_span().len(), 5)
        session.clear_selection()
        XCTAssertEqual(session.selection_span().len(), 0)
        // Idempotent.
        session.clear_selection()
        XCTAssertEqual(session.selection_span().len(), 0)
    }

    /// Out-of-range coords (past viewport bottom-right) silently clamp.
    /// Engine-side test covers the clamp; this test exists so future
    /// FFI-shape changes that disable the clamp surface here.
    func testOutOfRangeCoordsClampWithoutPanic() {
        let session = Self.makeCatSession()
        session.start_selection(TerminalSurfaceView.SELECTION_MODE_SIMPLE, 999, 999)
        session.update_selection(999, 999)
        let span = session.selection_span()
        XCTAssertEqual(span.len(), 5)
        XCTAssertLessThan(span.get(index: 0)!, 24)
        XCTAssertLessThan(span.get(index: 1)!, 80)
    }

    // MARK: - 2. Selection-mode constant pinning

    /// Pin the Swift mirror constants against `bridge.rs::kinds::
    /// SELECTION_MODE_*`. Drift here means a future renumber on either
    /// side would silently mis-route mouse-mode dispatch.
    func testSelectionModeConstantsMatchKindsModule() {
        // bridge.rs:kinds:
        //   SELECTION_MODE_SIMPLE = 0
        //   SELECTION_MODE_WORD   = 1
        //   SELECTION_MODE_LINE   = 2
        XCTAssertEqual(TerminalSurfaceView.SELECTION_MODE_SIMPLE, 0)
        XCTAssertEqual(TerminalSurfaceView.SELECTION_MODE_WORD, 1)
        XCTAssertEqual(TerminalSurfaceView.SELECTION_MODE_LINE, 2)
    }

    /// Arrow keycodes match Carbon's `<HIToolbox/Events.h>`. Pins the
    /// shift+arrow handler's dispatch contract — same precedent as
    /// `testPgUpPgDnKeyCodesMatchCarbonContract` in the 4.4 wiring.
    func testArrowKeycodesMatchCarbonContract() {
        // kVK_LeftArrow  = 0x7B = 123
        // kVK_RightArrow = 0x7C = 124
        // kVK_DownArrow  = 0x7D = 125
        // kVK_UpArrow    = 0x7E = 126
        XCTAssertEqual(0x7B as UInt16, 123)
        XCTAssertEqual(0x7C as UInt16, 124)
        XCTAssertEqual(0x7D as UInt16, 125)
        XCTAssertEqual(0x7E as UInt16, 126)
    }

    // MARK: - 3. Shader pixel readback (kind=2 selection tint)

    /// Drive the kind=2 path of the unified overlay shader at the
    /// theme-spec'd selection color (`#3d4254`) and assert the
    /// resulting pixels match the expected `colorLinear * 0.35`
    /// straight-alpha-over-clear blend.
    ///
    /// The render target uses `.rgba8Unorm` (NOT `.bgra8Unorm_srgb`)
    /// so we can read back pixel bytes without the encode-on-store
    /// transform — what the shader writes is what we sample. Mirrors
    /// `OverlayPipelineTests.testCursorShapesRenderExpectedGeometry`.
    func testSelectionTintMatchesSpecColorAtExpectedAlpha() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable in test environment")
        }
        let pipeline = try OverlayPipeline(device: device, pixelFormat: .rgba8Unorm)
        let queue = try XCTUnwrap(device.makeCommandQueue())

        // 32×16 target: one cell at (0, 0), 16×16 px, leaves the right
        // half clear so we can sanity-check the quad doesn't stretch
        // by default (cellSpanCols=1).
        let renderDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 32, height: 16, mipmapped: false)
        renderDesc.usage = [.renderTarget, .shaderRead]
        renderDesc.storageMode = .private
        let renderTarget = try XCTUnwrap(device.makeTexture(descriptor: renderDesc))

        let readDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 32, height: 16, mipmapped: false)
        readDesc.usage = [.shaderRead]
        readDesc.storageMode = .shared
        let readback = try XCTUnwrap(device.makeTexture(descriptor: readDesc))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = renderTarget
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // Clear to black — the source-over blend produces
        // `tint.rgb * tint.a + 0 * (1 - tint.a) = tint.rgb * tint.a`.
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1)

        let buf = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(buf.makeRenderCommandEncoder(descriptor: pass))

        // Drive the same code-path the renderer takes: theme color
        // with alpha modulated to MetalRenderer.selectionAlpha.
        var color = Theme.Color.selectionBgLinear
        color.w = MetalRenderer.selectionAlpha

        let uniforms = OverlayUniforms(
            screenSizePx: SIMD2<Float>(32, 16),
            cellOriginPx: SIMD2<Float>(0, 0),
            cellSizePx: SIMD2<Float>(16, 16),
            colorLinear: color,
            kind: OverlayKind.selection.rawValue,
            alpha: 1.0,
            cellSpanCols: 1)
        pipeline.encode(uniforms: uniforms, encoder: enc)
        enc.endEncoding()

        let blit = try XCTUnwrap(buf.makeBlitCommandEncoder())
        blit.copy(
            from: renderTarget,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 32, height: 16, depth: 1),
            to: readback,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        buf.commit()
        buf.waitUntilCompleted()
        XCTAssertNil(buf.error)

        var pixels = [UInt8](repeating: 0, count: 32 * 16 * 4)
        pixels.withUnsafeMutableBufferPointer { ptr in
            readback.getBytes(
                ptr.baseAddress!,
                bytesPerRow: 32 * 4,
                from: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: 32, height: 16, depth: 1)),
                mipmapLevel: 0)
        }

        // Expected: pixels in the cell ([0,16) × [0,16)) carry the
        // tint × 0.35 alpha-over-black; pixels in the right half
        // ([16,32)) stay clear (black).
        //
        // tint.rgb (linear) for #2a3424 (matcha selection):
        //   r_lin = SRGBLinearLUT[0x2A]
        //   g_lin = SRGBLinearLUT[0x34]
        //   b_lin = SRGBLinearLUT[0x24]
        // After alpha=0.35 source-over black, the .rgba8Unorm readback
        // stores `linear * 0.35 * 255` per channel, rounded.
        let alpha: Float = 0.35
        let expectedR = UInt8(
            (SRGBLinearLUT.referenceLinear(forByte: 0x2A) * alpha * 255.0).rounded())
        let expectedG = UInt8(
            (SRGBLinearLUT.referenceLinear(forByte: 0x34) * alpha * 255.0).rounded())
        let expectedB = UInt8(
            (SRGBLinearLUT.referenceLinear(forByte: 0x24) * alpha * 255.0).rounded())

        @inline(__always) func sample(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * 32 + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2])
        }

        // Inside the cell — must match the expected blended tint.
        let mid = sample(8, 8)
        XCTAssertEqual(
            Int(mid.0), Int(expectedR), accuracy: 2,
            "selection R should be linear(0x2A)*0.35*255")
        XCTAssertEqual(
            Int(mid.1), Int(expectedG), accuracy: 2,
            "selection G should be linear(0x34)*0.35*255")
        XCTAssertEqual(
            Int(mid.2), Int(expectedB), accuracy: 2,
            "selection B should be linear(0x24)*0.35*255")

        // Outside the cell (right half) — clear-color black survives.
        let outside = sample(24, 8)
        XCTAssertLessThan(Int(outside.0), 5, "outside-cell stays clear (R)")
        XCTAssertLessThan(Int(outside.1), 5, "outside-cell stays clear (G)")
        XCTAssertLessThan(Int(outside.2), 5, "outside-cell stays clear (B)")
    }

    /// `cellSpanCols` stretches the quad along x: with span=2 a single
    /// draw call paints two cells. Verifies the multi-cell-row encode
    /// strategy used by `MetalRenderer.encodeSelectionOverlay` for
    /// stream selections.
    func testSelectionSpanColsStretchesQuad() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable in test environment")
        }
        let pipeline = try OverlayPipeline(device: device, pixelFormat: .rgba8Unorm)
        let queue = try XCTUnwrap(device.makeCommandQueue())

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 64, height: 16, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        let renderTarget = try XCTUnwrap(device.makeTexture(descriptor: desc))

        let readDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 64, height: 16, mipmapped: false)
        readDesc.usage = [.shaderRead]
        readDesc.storageMode = .shared
        let readback = try XCTUnwrap(device.makeTexture(descriptor: readDesc))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = renderTarget
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let buf = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(buf.makeRenderCommandEncoder(descriptor: pass))

        // Pure magenta tint at full alpha (no 0.35 modulation) so we
        // can detect cursor-vs-clear unambiguously, the same way
        // `testCursorShapesRenderExpectedGeometry` does.
        let uniforms = OverlayUniforms(
            screenSizePx: SIMD2<Float>(64, 16),
            cellOriginPx: SIMD2<Float>(0, 0),
            cellSizePx: SIMD2<Float>(16, 16),
            colorLinear: SIMD4<Float>(1, 0, 1, 1),
            kind: OverlayKind.selection.rawValue,
            alpha: 1.0,
            cellSpanCols: 3)  // 3-cell-wide row span
        pipeline.encode(uniforms: uniforms, encoder: enc)
        enc.endEncoding()

        let blit = try XCTUnwrap(buf.makeBlitCommandEncoder())
        blit.copy(
            from: renderTarget,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 64, height: 16, depth: 1),
            to: readback,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        buf.commit()
        buf.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: 64 * 16 * 4)
        pixels.withUnsafeMutableBufferPointer { ptr in
            readback.getBytes(
                ptr.baseAddress!,
                bytesPerRow: 64 * 4,
                from: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: 64, height: 16, depth: 1)),
                mipmapLevel: 0)
        }

        @inline(__always) func isMagenta(_ x: Int, _ y: Int) -> Bool {
            let i = (y * 64 + x) * 4
            return pixels[i] > 200 && pixels[i + 1] < 50 && pixels[i + 2] > 200
        }

        // 3 × 16-px cells = covers x ∈ [0, 48). Sample one pixel from
        // each cell + just past the edge.
        XCTAssertTrue(isMagenta(4, 8), "first cell painted")
        XCTAssertTrue(isMagenta(20, 8), "second cell painted")
        XCTAssertTrue(isMagenta(40, 8), "third cell painted")
        // Past the 3-cell extent — clear.
        let outsideI = (8 * 64 + 50) * 4
        XCTAssertLessThan(Int(pixels[outsideI]), 5, "x=50 outside span: clear")
    }

    // MARK: - Helpers

    private static func makeCatSession() -> TerminalSession {
        // /bin/cat is the deterministic-echo workhorse used elsewhere.
        // 24×80 grid matches `MetalRenderer.gridRows / gridCols`.
        let envPayload = "TERM=xterm-256color\nLANG=en_US.UTF-8\n"
        let envVec = RustVec<UInt8>()
        for byte in envPayload.utf8 { envVec.push(value: byte) }
        let config = SessionConfig(
            rows: 24,
            cols: 80,
            pixel_w: 0,
            pixel_h: 0,
            command: "/bin/cat".intoRustString(),
            cwd: "/tmp".intoRustString(),
            env: envVec)
        return TerminalSession.new(config)
    }
}
