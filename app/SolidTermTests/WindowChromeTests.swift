// Phase 1 Week 4 task 4.8: window-chrome plumbing.
//
// Coverage:
//   - `MetalRenderer.resizeGrid(cols:rows:)`:
//       * happy-path: instance vars + viewport accessors update
//       * idempotent: same dims twice rebuilds pipeline only once
//       * defensive: zero / negative dims are no-ops
//   - `TerminalSurfaceView.setFrameSize(_:)`:
//       * propagates new dims to the renderer post-windowChanged
//
// Live drag-resize behaviour can't be fully synthesized in xctest
// (NSEvent mouse-drag injection in a windowless test rig is brittle),
// so this file pins the renderer-facing contract via direct
// `setFrameSize` invocation. The full drag-corner-with-mouse
// verification owes to user dogfood.

import AppKit
import XCTest

@testable import SolidTerm

final class WindowChromeTests: XCTestCase {
    /// Build a TerminalSurfaceView attached to a real window so the
    /// renderer can complete its `windowChanged` init (atlas + grid
    /// pipeline). Without a window the atlas is nil and `resizeGrid`
    /// short-circuits; we want to exercise the rebuild path.
    private func makeSurfaceWindow() -> (NSWindow, TerminalSurfaceView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false)
        let view = TerminalSurfaceView(frame: window.contentLayoutRect)
        window.contentView = view
        window.makeKey()
        return (window, view)
    }

    // MARK: - MetalRenderer.resizeGrid

    func testResizeGridUpdatesInstanceVars() {
        let (_, view) = makeSurfaceWindow()
        let renderer = view.rendererForTesting

        // Post-attach the grid is sized to the 800×480 contentView
        // (Bug 3 fix — `viewDidMoveToWindow` propagates view size to
        // the renderer once the atlas is built). Capture whatever
        // dimensions land and pin the resize-mutates-them invariant
        // independently of the precise cell metrics.
        let initialCols = renderer.gridCols
        let initialRows = renderer.gridRows
        XCTAssertGreaterThan(
            initialCols, 0, "Post-attach grid cols must be set")
        XCTAssertGreaterThan(
            initialRows, 0, "Post-attach grid rows must be set")
        XCTAssertFalse(
            initialCols == 100 && initialRows == 30,
            "Test setup must not coincidentally land at the resize "
                + "target — otherwise the assertion is trivial")

        renderer.resizeGrid(cols: 100, rows: 30)

        XCTAssertEqual(renderer.gridCols, 100)
        XCTAssertEqual(renderer.gridRows, 30)
        XCTAssertEqual(renderer.viewportCols, 100, "viewport accessor reflects live grid")
        XCTAssertEqual(renderer.viewportRows, 30)
    }

    func testResizeGridIsIdempotentForSameDimensions() {
        let (_, view) = makeSurfaceWindow()
        let renderer = view.rendererForTesting

        renderer.resizeGrid(cols: 100, rows: 30)
        let countAfterFirst = renderer.resizeRebuildCount

        renderer.resizeGrid(cols: 100, rows: 30)
        XCTAssertEqual(
            renderer.resizeRebuildCount, countAfterFirst,
            "Same-dims resize must not trigger a pipeline rebuild")

        // Different dims do tick the counter.
        renderer.resizeGrid(cols: 132, rows: 40)
        XCTAssertEqual(
            renderer.resizeRebuildCount, countAfterFirst + 1,
            "Different-dims resize triggers exactly one rebuild")
    }

    func testResizeGridRejectsZeroDimensions() {
        let (_, view) = makeSurfaceWindow()
        let renderer = view.rendererForTesting
        let beforeCols = renderer.gridCols
        let beforeRows = renderer.gridRows
        let beforeRebuilds = renderer.resizeRebuildCount

        renderer.resizeGrid(cols: 0, rows: 30)
        XCTAssertEqual(renderer.gridCols, beforeCols, "cols=0 must not mutate")
        XCTAssertEqual(renderer.gridRows, beforeRows)

        renderer.resizeGrid(cols: 100, rows: 0)
        XCTAssertEqual(renderer.gridCols, beforeCols, "rows=0 must not mutate")
        XCTAssertEqual(renderer.gridRows, beforeRows)

        renderer.resizeGrid(cols: -5, rows: 30)
        XCTAssertEqual(renderer.gridCols, beforeCols, "negative cols must not mutate")
        XCTAssertEqual(
            renderer.resizeRebuildCount, beforeRebuilds,
            "Defensive early-returns must not tick the rebuild counter")
    }

    func testResizeGridPropagatesToEngineSession() {
        let (_, view) = makeSurfaceWindow()
        let renderer = view.rendererForTesting

        renderer.resizeGrid(cols: 132, rows: 40)

        // The Rust engine's rows()/cols() must reflect the resize.
        // Session is constructed in windowChanged, so it's available.
        guard let session = renderer.session else {
            XCTFail("Session must exist after windowChanged")
            return
        }
        XCTAssertEqual(Int(session.rows()), 40)
        XCTAssertEqual(Int(session.cols()), 132)
    }

    // MARK: - TerminalSurfaceView.setFrameSize → renderer

    func testSetFrameSizeTriggersGridResize() {
        let (window, view) = makeSurfaceWindow()
        let renderer = view.rendererForTesting

        guard let cellWidth = renderer.cellWidthPt,
            let cellHeight = renderer.cellHeightPt,
            cellWidth > 0, cellHeight > 0
        else {
            XCTFail("Atlas must be built post-windowChanged")
            return
        }

        // Pick a frame size that yields a clean target grid. M5.5-3:
        // the cell grid is sibling to a 24pt gutter; window content =
        // gutter + cols × cellWidth. Without this, the grid loses
        // ~3 cols and the assertion is off by `gutter / cellWidth`.
        let targetCols = 100
        let targetRows = 30
        let newSize = NSSize(
            width: Theme.Gutter.widthPt + cellWidth * CGFloat(targetCols),
            height: cellHeight * CGFloat(targetRows))
        view.setFrameSize(newSize)

        XCTAssertEqual(
            renderer.gridCols, targetCols,
            "setFrameSize must drive renderer.gridCols")
        XCTAssertEqual(renderer.gridRows, targetRows)
        _ = window  // silence unused warning; window holds view alive
    }

    /// Initial-attach grid dimensions must reflect the actual view
    /// frame, not the default 80×24. Pins the dogfood regression
    /// where `setFrameAutosaveName` restored a 1440×800 window but
    /// the renderer kept the spike defaults — leaving the grid as a
    /// small island in the upper-left of a much larger drawable. The
    /// fix is the explicit `propagateGridSizeToRenderer` call inside
    /// `viewDidMoveToWindow` after `windowChanged` has built the
    /// atlas.
    func testInitialGridDimsTrackWindowSizeAfterAttach() {
        // 1200×800 — well outside the 80×24 = 672×336 default.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false)
        let view = TerminalSurfaceView(frame: window.contentLayoutRect)
        window.contentView = view
        window.makeKey()

        let renderer = view.rendererForTesting

        // Atlas must be built — the propagation path needs cellWidthPt.
        guard let cellWidth = renderer.cellWidthPt,
            let cellHeight = renderer.cellHeightPt,
            cellWidth > 0, cellHeight > 0
        else {
            XCTFail("Atlas must be built post-windowChanged")
            return
        }

        // M5.5-3: subtract gutter from the available width before
        // floor-dividing — `propagateGridSizeToRenderer` does the same.
        let gridWidth = max(0, view.bounds.size.width - Theme.Gutter.widthPt)
        let expectedCols = max(
            1, Int((gridWidth / cellWidth).rounded(.down)))
        let expectedRows = max(
            1, Int((view.bounds.size.height / cellHeight).rounded(.down)))

        XCTAssertNotEqual(
            expectedCols, 80,
            "Test setup must produce a non-default grid width — "
                + "otherwise the assertion is trivially satisfied")

        XCTAssertEqual(
            renderer.gridCols, expectedCols,
            "After viewDidMoveToWindow, gridCols must reflect "
                + "the actual view size (not the 80×24 default)")
        XCTAssertEqual(
            renderer.gridRows, expectedRows,
            "After viewDidMoveToWindow, gridRows must reflect "
                + "the actual view size (not the 80×24 default)")
    }

    func testSetFrameSizeFloorsFractionalDimensions() {
        let (_, view) = makeSurfaceWindow()
        let renderer = view.rendererForTesting

        guard let cellWidth = renderer.cellWidthPt,
            let cellHeight = renderer.cellHeightPt
        else {
            XCTFail("Atlas must be built post-windowChanged")
            return
        }

        // Width = gutter + 100.7 cells, height = 30.4 cells → floor =
        // 100×30. Gutter is added before floor-dividing per the M5.5-3
        // layout contract.
        let newSize = NSSize(
            width: Theme.Gutter.widthPt + cellWidth * 100.7,
            height: cellHeight * 30.4)
        view.setFrameSize(newSize)

        XCTAssertEqual(
            renderer.gridCols, 100,
            "Fractional excess width must floor down (no partial trailing cell)")
        XCTAssertEqual(renderer.gridRows, 30)
    }
}
