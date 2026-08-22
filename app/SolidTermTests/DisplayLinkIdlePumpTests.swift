// Guards the stall detector behind `MetalRenderer`'s idle pump.
// `poll_output` — the only drain of the bounded PTY reader channel —
// runs from `draw(update:)`, which macOS stops calling whenever the
// display sleeps or the window is fully occluded. Without the pump the
// channel fills, the reader thread parks in `send`, the PTY master
// buffer backs up, and the child blocks in `write()`: every process in
// the pane freezes until the display returns. Observed as a 7.6 h
// stall of a long-running CLI across an overnight display sleep.

import XCTest

@testable import SolidTerm

final class DisplayLinkIdlePumpTests: XCTestCase {

    private let threshold = MetalRenderer.displayLinkStallThresholdSec
    private let now: CFTimeInterval = 1_000

    /// A link pinned to its 30 Hz floor ticks every ~33 ms, far inside
    /// the threshold: the pump must stay out of a healthy link's way,
    /// or it would discard deltas the renderer was about to draw.
    func testHealthyLinkIsNotStalled() {
        XCTAssertFalse(
            MetalRenderer.displayLinkStalled(now: now, lastTick: now - 0.033))
        XCTAssertFalse(
            MetalRenderer.displayLinkStalled(now: now, lastTick: now - threshold))
    }

    func testStoppedLinkIsStalled() {
        XCTAssertTrue(
            MetalRenderer.displayLinkStalled(
                now: now, lastTick: now - threshold - 0.001))
        // The motivating case: an overnight display sleep.
        XCTAssertTrue(
            MetalRenderer.displayLinkStalled(now: now, lastTick: now - 7.6 * 3600))
    }

    /// Between session spawn and the first frame no tick has landed.
    /// The pump must cover that window too, so the `0` seed has to
    /// read as stalled rather than as "just ticked".
    func testUninitializedLastTickCountsAsStalled() {
        XCTAssertTrue(MetalRenderer.displayLinkStalled(now: now, lastTick: 0))
    }
}
