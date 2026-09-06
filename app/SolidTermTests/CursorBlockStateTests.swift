// Pins `MetalRenderer.computeCursorBlockState()`, the per-frame cursor
// resolution both passes read: the grid pass reverse-videos the BLOCK
// cell from it, the overlay pass encodes the BEAM / UNDERLINE quad from
// it, and it is the only place the blink bookkeeping advances. Ticket 14
// moves it into an extension file, so the gates and the phase logic get
// a net first (spec D10).
//
// Nothing here touches the GPU. Everything the helper reads is drivable
// from a headless renderer: `lastCursor` and `lastScrollTop` are plain
// state, the grid bounds come from `resizeGrid(cols:rows:)`, the cursor
// colour from `resolvedCursor`, and time from `MetalRenderer.now` —
// ticket 07's injected clock, which is what makes the blink phase a
// value assertion instead of a sleep.
//
// `OverlayEncoderPixelTests` covers what the encoder draws from a
// `CursorBlockState`; this file covers which one it is handed.

import Metal
import XCTest

@testable import SolidTerm

@MainActor
final class CursorBlockStateTests: XCTestCase {

    // MARK: - Helpers

    private static let cols = 8
    private static let rows = 4

    /// An arbitrary but fixed clock reading. The helper anchors the
    /// blink origin to the first reading it takes, so every phase in
    /// these tests is measured relative to this, not to launch time.
    private static let t0: CFTimeInterval = 1_000

    private func makeRenderer() throws -> MetalRenderer {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = MetalRenderer(device: device)
        renderer.resizeGrid(cols: Self.cols, rows: Self.rows)
        renderer.now = { Self.t0 }
        return renderer
    }

    /// A visible, steady, in-bounds block cursor — the shape every gate
    /// test starts from so a `nil` can only come from the gate it flips.
    private func cursor(
        row: UInt16 = 1, col: UInt16 = 2, shape: UInt8 = 0,
        blink: Bool = false, hidden: Bool = false
    ) -> CursorState {
        CursorState(row: row, col: col, shape: shape, blink: blink, hidden: hidden)
    }

    // MARK: - Visibility gates

    /// Before the first frame there is no cursor to resolve. The Phase-1
    /// stub always produced one, so this guards the future producer that
    /// does not.
    func testNoFrameYetDrawsNothing() throws {
        let renderer = try makeRenderer()
        XCTAssertNil(renderer.lastCursor)
        XCTAssertNil(renderer.computeCursorBlockState())
    }

    /// DECTCEM off: the grid pass must not reverse-video the cell either,
    /// which is exactly why the gate lives here and not in the encoder.
    func testHiddenCursorDrawsNothing() throws {
        let renderer = try makeRenderer()
        renderer.lastCursor = cursor(hidden: true)
        XCTAssertNil(renderer.computeCursorBlockState())

        renderer.lastCursor = cursor(hidden: false)
        XCTAssertNotNil(
            renderer.computeCursorBlockState(),
            "the same renderer must draw again once DECTCEM shows the cursor")
    }

    /// UX3: scrolled into history, a block on old output reads as "this
    /// line is editable". Nothing draws until the view snaps back.
    func testScrolledIntoHistoryDrawsNothing() throws {
        let renderer = try makeRenderer()
        renderer.lastCursor = cursor()

        renderer.lastScrollTop = 1
        XCTAssertNil(renderer.computeCursorBlockState())

        renderer.lastScrollTop = 0
        XCTAssertNotNil(
            renderer.computeCursorBlockState(),
            "snap-to-bottom must bring the cursor back")
    }

    /// Defensive bound: a producer that placed the cursor past the grid
    /// would otherwise reverse-video a cell that is not on screen.
    func testOffGridCursorDrawsNothing() throws {
        let renderer = try makeRenderer()

        renderer.lastCursor = cursor(row: UInt16(Self.rows), col: 0)
        XCTAssertNil(renderer.computeCursorBlockState(), "row past the last one")

        renderer.lastCursor = cursor(row: 0, col: UInt16(Self.cols))
        XCTAssertNil(renderer.computeCursorBlockState(), "column past the last one")

        // The last legal cell is inside, and it comes back unmoved.
        renderer.lastCursor = cursor(row: UInt16(Self.rows - 1), col: UInt16(Self.cols - 1))
        let state = try XCTUnwrap(renderer.computeCursorBlockState())
        XCTAssertEqual(state.row, Self.rows - 1)
        XCTAssertEqual(state.col, Self.cols - 1)
    }

    // MARK: - Shape mapping

    /// The DECSCUSR byte the engine hands over picks the overlay kind.
    /// An unknown byte falls back to the block — never to "no cursor",
    /// which would leave the user without an insertion point.
    func testShapeByteSelectsTheOverlayKind() throws {
        let renderer = try makeRenderer()
        let cases: [(UInt8, OverlayKind)] = [
            (0, .cursorBlock), (1, .cursorBeam), (2, .cursorUnderline), (9, .cursorBlock),
        ]
        for (shape, expected) in cases {
            renderer.lastCursor = cursor(shape: shape)
            let state = try XCTUnwrap(renderer.computeCursorBlockState())
            XCTAssertEqual(state.kind, expected, "shape byte \(shape)")
            XCTAssertEqual(MetalRenderer.cursorKind(forShape: shape), expected)
        }
    }

    // MARK: - Colour

    /// The uniform's `alpha` carries the blink phase, so the colour has
    /// to leave the helper opaque or the overlay's `colorLinear.a * alpha`
    /// term would multiply the fade in twice.
    func testColourIsTheResolvedCursorForcedOpaque() throws {
        let renderer = try makeRenderer()
        renderer.resolvedCursor = SIMD4<Float>(0.125, 0.25, 0.5, 0.25)
        renderer.lastCursor = cursor()

        let state = try XCTUnwrap(renderer.computeCursorBlockState())
        XCTAssertEqual(state.color.x, 0.125, accuracy: 0.0001)
        XCTAssertEqual(state.color.y, 0.25, accuracy: 0.0001)
        XCTAssertEqual(state.color.z, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.color.w, 1.0, accuracy: 0.0001, "the phase rides on alpha, not here")
    }

    // MARK: - Blink phase

    /// The phase is measured from the first reading the helper takes,
    /// not from process start, so a window that appears seconds into the
    /// run still enters at visible-steady. Sample points are fractions
    /// of `blinkPeriodSec` so a change to the period moves them with it;
    /// which band each fraction lands in is fixed by `easedBlinkAlpha`.
    func testBlinkPhaseFollowsTheInjectedClock() throws {
        let renderer = try makeRenderer()
        renderer.lastCursor = cursor(blink: true)
        let period = MetalRenderer.blinkPeriodSec

        renderer.now = { Self.t0 }
        XCTAssertEqual(
            try XCTUnwrap(renderer.computeCursorBlockState()).alpha, 1.0,
            "the first frame anchors the phase and enters solid")

        // Mid fade-out: still drawn, no longer solid.
        renderer.now = { Self.t0 + 0.35 * period }
        let fading = try XCTUnwrap(renderer.computeCursorBlockState())
        XCTAssertGreaterThan(fading.alpha, 0)
        XCTAssertLessThan(fading.alpha, 1.0)

        // Hidden-steady dwell: `nil` is how both passes learn to skip.
        renderer.now = { Self.t0 + 0.6 * period }
        XCTAssertNil(renderer.computeCursorBlockState())

        // One full period on from the anchor, back at visible-steady.
        renderer.now = { Self.t0 + period }
        XCTAssertEqual(try XCTUnwrap(renderer.computeCursorBlockState()).alpha, 1.0)
    }

    /// A DECSCUSR steady shape must never fade, whatever the clock says.
    func testNonBlinkingCursorIgnoresThePhase() throws {
        let renderer = try makeRenderer()
        renderer.lastCursor = cursor(blink: false)

        renderer.now = { Self.t0 }
        XCTAssertEqual(try XCTUnwrap(renderer.computeCursorBlockState()).alpha, 1.0)

        renderer.now = { Self.t0 + 0.6 * MetalRenderer.blinkPeriodSec }
        XCTAssertEqual(
            try XCTUnwrap(renderer.computeCursorBlockState()).alpha, 1.0,
            "a steady cursor has no hidden-steady dwell to land in")
    }

    // MARK: - Pause on type

    /// V2 pause-on-type plus the UX6 re-anchor. Sampled inside the
    /// period's fade-out phase and inside the keystroke pause, so a
    /// solid reading can only come from the pause; the control renderer
    /// is the same setup minus the keystroke.
    func testTypingHoldsTheCursorSolidAndReanchorsOnRelease() throws {
        let period = MetalRenderer.blinkPeriodSec
        let hold = MetalRenderer.blinkPauseAfterKeystrokeSec
        let sample = 0.35 * period
        XCTAssertLessThan(sample, hold, "the sample has to sit inside the pause window")

        let typing = try makeRenderer()
        typing.lastCursor = cursor(blink: true)
        typing.now = { Self.t0 }
        _ = typing.computeCursorBlockState()  // anchors the phase at t0
        // The stamp comes from the injected clock, not from this
        // argument — `recordKeystroke` takes `NSEvent.timestamp` for the
        // latency meter and calls `now()` for the pause window.
        typing.recordKeystroke(eventTimestamp: Self.t0)

        typing.now = { Self.t0 + sample }
        XCTAssertEqual(
            try XCTUnwrap(typing.computeCursorBlockState()).alpha, 1.0,
            "the insertion point holds solid while the user types")

        let idle = try makeRenderer()
        idle.lastCursor = cursor(blink: true)
        idle.now = { Self.t0 }
        _ = idle.computeCursorBlockState()
        idle.now = { Self.t0 + sample }
        XCTAssertLessThan(
            try XCTUnwrap(idle.computeCursorBlockState()).alpha, 1.0,
            "control: without the keystroke that same instant is mid-fade")

        // UX6: the first idle frame after the pause re-anchors, so the
        // cursor re-enters visible-steady instead of reappearing
        // wherever the free-running phase had drifted to.
        let released = Self.t0 + hold + 0.001
        typing.now = { released }
        XCTAssertEqual(
            try XCTUnwrap(typing.computeCursorBlockState()).alpha, 1.0,
            "typing → idle must resume from the visible-steady phase")

        // ...and the phase runs on from that new anchor.
        typing.now = { released + 0.6 * period }
        XCTAssertNil(typing.computeCursorBlockState())
    }
}
