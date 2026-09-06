// Pins the per-window font-size controls on `MetalRenderer` — ⌘+ / ⌘- /
// ⌘0 and the atlas rebuild behind them. Ticket 14 moves them out of
// `MetalRenderer.swift` into an extension file, so the behaviour gets a
// net first (spec D10).
//
// The override arithmetic needs nothing but a headless renderer (the
// `MetalRendererFontTests` pattern): `bumpFontSize` / `dropFontSize` /
// `resetFontSize` clamp the next size, return early when the clamp
// leaves it where it was, then move `fontSizeOverride`, raise
// `atlasDirty` and delegate to `reloadFont()`. That early return is
// what makes the saturation cases stop rather than wrap. The rebuild
// itself does need a host window —
// `reloadFont()`'s first guard is `hostWindow` — so the cell-metric
// tests hand the renderer a real offscreen `NSWindow` through
// `windowChanged(window:)`, the production setter. With no `CAMetalLayer`
// attached that call returns right after capturing the window, which
// keeps the display link, the idle pump and the engine session out of
// the picture.

import AppKit
import Metal
import XCTest

@testable import SolidTerm

@MainActor
final class MetalRendererFontSizeTests: XCTestCase {

    // MARK: - Helpers

    /// Windows handed to a renderer. `MetalRenderer.hostWindow` is
    /// `weak`, so the test has to own the strong reference for as long
    /// as the renderer is expected to still see the window.
    private var windows: [NSWindow] = []

    private func makeRenderer() throws -> MetalRenderer {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return MetalRenderer(device: device)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        windows.append(window)
        return window
    }

    /// `FontSettings.shared` is process-wide and UserDefaults-backed, so
    /// a sibling test that bumped it would otherwise decide this test's
    /// baseline. Pin it to the documented default and hand the value
    /// back so the assertions can be written relative to it.
    private func pinGlobalSize() -> CGFloat {
        FontSettings.shared.resetSize()
        return FontSettings.shared.size
    }

    // MARK: - Override arithmetic

    /// ⌘+ / ⌘- step the per-window override by one point each press and
    /// leave the global setting — every other window's size — alone.
    func testBumpAndDropStepTheOverrideOnePointPerPress() throws {
        let renderer = try makeRenderer()
        let base = pinGlobalSize()
        defer { FontSettings.shared.resetSize() }

        XCTAssertNil(
            renderer.fontSizeOverrideForTesting,
            "a fresh renderer follows the global size, it does not pin one")

        renderer.bumpFontSize()
        XCTAssertEqual(renderer.fontSizeOverrideForTesting, base + 1)
        renderer.bumpFontSize()
        XCTAssertEqual(renderer.fontSizeOverrideForTesting, base + 2)
        renderer.dropFontSize()
        XCTAssertEqual(renderer.fontSizeOverrideForTesting, base + 1)

        XCTAssertEqual(
            FontSettings.shared.size, base,
            "⌘+ is per-window; the global picker must not move with it")
    }

    /// The hotkeys saturate rather than run off the end of the clamp —
    /// a key held down must not push the atlas at a 60 pt font.
    func testBumpSaturatesAtTheMaximumSize() throws {
        let renderer = try makeRenderer()
        _ = pinGlobalSize()
        defer { FontSettings.shared.resetSize() }

        // One press per point across the whole band, plus a few past it.
        for _ in 0..<(Int(FontSettings.maxSize - FontSettings.minSize) + 4) {
            renderer.bumpFontSize()
        }
        XCTAssertEqual(renderer.fontSizeOverrideForTesting, FontSettings.maxSize)
    }

    func testDropSaturatesAtTheMinimumSize() throws {
        let renderer = try makeRenderer()
        _ = pinGlobalSize()
        defer { FontSettings.shared.resetSize() }

        for _ in 0..<(Int(FontSettings.maxSize - FontSettings.minSize) + 4) {
            renderer.dropFontSize()
        }
        XCTAssertEqual(renderer.fontSizeOverrideForTesting, FontSettings.minSize)
    }

    /// ⌘0 clears the override instead of writing `FontSettings.defaultSize`
    /// into it: the window goes back to *following* the global picker,
    /// which is a different thing whenever the user has changed it.
    func testResetReturnsTheWindowToFollowingTheGlobalSize() throws {
        let renderer = try makeRenderer()
        let base = pinGlobalSize()
        defer { FontSettings.shared.resetSize() }

        renderer.bumpFontSize()
        renderer.bumpFontSize()
        XCTAssertEqual(renderer.fontSizeOverrideForTesting, base + 2)

        renderer.resetFontSize()
        XCTAssertNil(
            renderer.fontSizeOverrideForTesting,
            "⌘0 drops the override rather than pinning the default size")

        // The proof that "follow" is live and not a snapshot: move the
        // global, and the next ⌘+ steps from the new value.
        FontSettings.shared.increaseSize()
        renderer.bumpFontSize()
        XCTAssertEqual(renderer.fontSizeOverrideForTesting, base + 2)
    }

    // MARK: - Atlas rebuild

    /// `reloadFont()` re-rasterizes the atlas against the *effective*
    /// size, and the cell metrics the rest of the renderer measures in
    /// (`cellWidthPt` / `cellHeightPt`, both derived from the atlas)
    /// move with it. `GlyphAtlas.cellSize(for:)` ceils the advance and
    /// the ascent+descent+leading, so the four-point step is deliberate:
    /// a single point can round to the same integer width.
    func testReloadFontRederivesTheCellFromTheEffectiveSize() throws {
        let renderer = try makeRenderer()
        _ = pinGlobalSize()
        defer { FontSettings.shared.resetSize() }

        XCTAssertNil(renderer.cellHeightPt, "no atlas before a window arrives")
        renderer.windowChanged(window: makeWindow())

        XCTAssertTrue(renderer.reloadFont(), "a renderer with a host window rebuilds")
        let baseWidth = try XCTUnwrap(renderer.cellWidthPt)
        let baseHeight = try XCTUnwrap(renderer.cellHeightPt)

        for _ in 0..<4 { renderer.bumpFontSize() }
        XCTAssertGreaterThan(
            try XCTUnwrap(renderer.cellHeightPt), baseHeight,
            "four points larger must rasterize a taller cell")
        XCTAssertGreaterThan(
            try XCTUnwrap(renderer.cellWidthPt), baseWidth,
            "four points larger must rasterize a wider cell")
        XCTAssertFalse(
            renderer.atlasDirty,
            "each ⌘+ raises the flag; the rebuild behind it has to lower it")

        // ⌘0 goes back through the same rebuild, so the metrics return
        // to exactly the size the global picker resolves to.
        renderer.resetFontSize()
        XCTAssertEqual(try XCTUnwrap(renderer.cellHeightPt), baseHeight, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(renderer.cellWidthPt), baseWidth, accuracy: 0.001)
    }

    /// Without a window there is no backing scale to rasterize against,
    /// so the rebuild reports failure and builds nothing. It still
    /// lowers `atlasDirty`: `windowChanged(window:)` lowers it too and
    /// then builds the atlas itself, so nothing is owed to a renderer
    /// that has no window yet.
    func testReloadFontWithoutAWindowFailsWithoutBuildingAnAtlas() throws {
        let renderer = try makeRenderer()
        _ = pinGlobalSize()
        defer { FontSettings.shared.resetSize() }

        XCTAssertFalse(renderer.reloadFont(), "no host window, nothing to rebuild against")
        XCTAssertNil(renderer.cellHeightPt)
        XCTAssertNil(renderer.cellWidthPt)

        // ⌘+ is the only path that raises the flag, so drive it through
        // one: a failing rebuild that left the flag up would have every
        // later frame wait on a regen that can never happen.
        renderer.bumpFontSize()
        XCTAssertFalse(renderer.atlasDirty, "the failed rebuild still lowers the flag")
    }
}
