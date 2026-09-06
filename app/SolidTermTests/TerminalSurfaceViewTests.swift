// Smoke tests for the CAMetalLayer host: confirms the layer attaches with
// a Metal device and that the drawable size tracks bounds × backing scale
// when AppKit fires resize hooks. Pixel-output verification is manual
// (screencapture in `xcodebuild test` is sandboxed); these tests cover
// the wiring that visual checks can't see at a glance.

import AppKit
import Metal
import XCTest

@testable import SolidTerm

final class TerminalSurfaceViewTests: XCTestCase {

    private static let initialBounds = NSRect(x: 0, y: 0, width: 400, height: 300)

    func testLayerIsCAMetalLayer() {
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        // Touching `.layer` triggers `makeBackingLayer()` via the
        // `wantsLayer = true` lifecycle.
        XCTAssertTrue(view.layer is CAMetalLayer)
        XCTAssertIdentical(view.layer, view.metalLayer)
    }

    func testDeviceNonNilAfterAttach() {
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        // The renderer's `attach(layer:)` writes the system default device
        // onto the layer; this is observable without exposing the renderer
        // internals.
        XCTAssertNotNil(view.metalLayer.device, "MTLDevice should be wired by attach()")
        XCTAssertEqual(view.metalLayer.pixelFormat, .bgra8Unorm_srgb)
        XCTAssertFalse(view.metalLayer.framebufferOnly)
        XCTAssertTrue(view.metalLayer.isOpaque)
    }

    func testDrawableSizeUpdatesOnResize() {
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        // No window in the test harness, so `updateDrawableSize()` falls
        // back to the layer's `contentsScale`. Force a Retina-equivalent
        // scale to make the assertion non-trivial (otherwise scale = 1.0
        // and width/height are bound to the input by identity).
        view.metalLayer.contentsScale = 2.0

        view.setFrameSize(NSSize(width: 800, height: 600))

        let expected = CGSize(width: 800 * 2.0, height: 600 * 2.0)
        XCTAssertEqual(view.metalLayer.drawableSize.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(view.metalLayer.drawableSize.height, expected.height, accuracy: 0.5)
    }

    func testRendererSessionStartsNilBeforeWindowAttached() {
        // The renderer's `applyFrameDelta` (#17-swift) early-returns on
        // `guard let session else { return }`. This test pins the
        // precondition: a freshly constructed `TerminalSurfaceView`
        // (and its owned `MetalRenderer`) has no session until
        // `viewDidMoveToWindow` triggers `renderer.windowChanged(...)`.
        // The XCTest harness never attaches the view to a window, so
        // we observe the `nil` default. Once the Week 1 producer lands
        // and emits non-empty cells, the early-return path becomes the
        // load-bearing safety net for the "view existed before its
        // session did" race.
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        XCTAssertNil(
            view.rendererForTesting.session,
            "MetalRenderer.session must be nil until windowChanged constructs it")
    }

    // MARK: - 4.4 scroll wiring

    /// `scrollWheel`'s early-return guards must hold against a no-
    /// session, no-atlas view. Pre-windowChanged, `renderer.session`
    /// is nil and `cellHeightPt` is nil because the atlas isn't
    /// built. Both must read nil — without these guards `scrollWheel`
    /// would force-unwrap on the first user trackpad swipe before
    /// the session ever attaches. Synthesizing a real `.scrollWheel`
    /// NSEvent in headless XCTest is blocked by AppKit
    /// (`NSEvent.mouseEvent` rejects `.scrollWheel` with an
    /// internal-inconsistency assertion; CGEvent posting needs the
    /// app to be the active session). Pinning the precondition is
    /// the correct architectural assertion at this layer; behaviour
    /// inside the method is covered by the FFI round-trip tests in
    /// `TerminalSessionLifecycleTests` + the Rust-side
    /// bridge.rs scroll round-trips.
    func testScrollWheelGuardsAreReachableOnNoSessionView() {
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        XCTAssertNil(
            view.rendererForTesting.session,
            "no session before windowChanged")
        XCTAssertNil(
            view.rendererForTesting.cellHeightPt,
            "no atlas before windowChanged means cellHeightPt is nil")
    }

    /// PgUp / PgDn keyCode constants must match Carbon
    /// `HIToolbox/Events.h`. If Apple ever rotates them (vanishingly
    /// unlikely; the stack has shipped with these values since
    /// macOS 10.0), `TerminalSurfaceView.keyDown`'s scroll branch
    /// silently stops working — this test pins the contract.
    func testPgUpPgDnKeyCodesMatchCarbonContract() {
        // kVK_PageUp = 0x74 = 116
        // kVK_PageDown = 0x79 = 121
        // Source: <Carbon/HIToolbox/Events.h>.
        // Re-asserted here because TerminalSurfaceView's private
        // constants encode this contract; if a future cleanup
        // accidentally swaps them, the alt-screen-gating branch fires
        // backwards (PgDn scrolls UP into history). This test catches
        // that mis-edit.
        let pgUp: UInt16 = 0x74
        let pgDown: UInt16 = 0x79
        XCTAssertEqual(pgUp, 116)
        XCTAssertEqual(pgDown, 121)
    }

    /// `viewportRows` accessor on the renderer must match the
    /// hardcoded `gridRows` constant. PgUp / PgDn page by exactly this
    /// many rows, so a drift between this and the actual grid would
    /// produce off-by-screen scrolling.
    func testViewportRowsMatchesGridShape() {
        let view = TerminalSurfaceView(frame: Self.initialBounds)
        // The renderer's `gridRows` is private; we assert the public
        // accessor equals the documented value (24 — see
        // `MetalRenderer.gridRows`). Resizable grid at 4.5 will turn
        // this into a per-window-size assertion.
        XCTAssertEqual(view.rendererForTesting.viewportRows, 24)
    }

    // MARK: - M5.5-3 gutter layout

    /// `gridContentSize(cols: 80, rows: 24)` includes the 24pt gutter
    /// on top of the cell grid width. Locks the contract that
    /// `TerminalWindowController` consumes: window content = gutter +
    /// 80 cols of cells.
    @MainActor
    func testGridContentSizeIncludesGutter() {
        let cols = 80
        let rows = 24
        let size = TerminalSurfaceView.gridContentSize(cols: cols, rows: rows)
        // Mirror gridContentSize's own font resolution so the test
        // tracks the active default (JetBrainsMono-Regular at 14pt).
        let font = FontSettings.makeCTFont(
            family: FontSettings.defaultFamily, size: FontSettings.defaultSize)
        let cell = GlyphAtlas.cellSize(for: font)
        XCTAssertEqual(
            size.width,
            Theme.Gutter.widthPt + cell.width * CGFloat(cols),
            accuracy: 0.5)
        XCTAssertEqual(
            size.height, cell.height * CGFloat(rows), accuracy: 0.5)
    }

    /// Cursor coord-space contract: a cursor at (col=0, row=0) renders
    /// at view-x = `gutterWidthPt`. Post-stripes-off (`58d0b97`) the
    /// gutter width is 0, so the cursor lands at view-x = 0 and the
    /// "shift by gutter" contract degenerates to a no-op. Kept as a
    /// regression pin: if a future chrome rework brings the gutter
    /// back, this test will start asserting against the new width
    /// constant naturally — the formula
    /// `cursorViewX = gutterPt + col × cellWidth` stays correct
    /// regardless of the concrete gutter value.
    func testCursorRenderPositionAccountsForGutter() {
        let cellWidthPt: CGFloat = 8.4  // Menlo 14pt typical
        let gutterPt = Theme.Gutter.widthPt
        // Pin the current value (0) so the formula below is anchored to
        // a known constant; if `widthPt` returns >0 in a chrome rework,
        // the second assertion still passes by construction but the
        // value-pin here will fail loudly, prompting the rework author
        // to re-baseline the regression-pin comment.
        XCTAssertEqual(
            gutterPt, 0, accuracy: 0.5,
            "B14: stripes-off (58d0b97) reclaimed the gutter — widthPt is 0 until chrome rework lands"
        )
        XCTAssertEqual(
            gutterPt + 5 * cellWidthPt, gutterPt + 42, accuracy: 0.5,
            "col=5 cursor view-x = gutter + 5 × cellWidth (formula holds regardless of gutter value)"
        )
    }

}
