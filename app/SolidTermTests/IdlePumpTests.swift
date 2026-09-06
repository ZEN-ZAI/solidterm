// Guards what the idle pump *does*. `DisplayLinkIdlePumpTests` covers
// only the `displayLinkStalled` predicate; the action behind it —
// `pumpIfDisplayLinkStalled()` — is what actually drains the bounded
// PTY reader channel while the display link is stopped, and what flags
// the full repaint that puts the discarded delta's cells back on the
// next live tick.
//
// Driving that decision needs a clock the test owns, which is what
// `MetalRenderer.now` is for. The timer wiring (`startIdlePump`) stays
// out of scope: injecting the clock is enough to pin the decision, and
// a fake DispatchSource would only test DispatchSource.

import Metal
import XCTest

@testable import SolidTerm

@MainActor
final class IdlePumpTests: XCTestCase {

    // MARK: - Helpers

    /// A real engine-backed session, same shape as
    /// `TerminalSessionLifecycleTests.sampleConfig`. The pump's first
    /// guard is `session != nil` and its side effect is a real
    /// `take_frame_delta()`, so the test drives the production path
    /// rather than a stand-in.
    private func makeSession() -> TerminalSession? {
        let env = RustVec<UInt8>()
        for byte in "TERM=xterm-256color\nLANG=en_US.UTF-8\n".utf8 {
            env.push(value: byte)
        }
        return TerminalSession.new(
            SessionConfig(
                rows: 24, cols: 80, pixel_w: 0, pixel_h: 0,
                command: "/bin/zsh".intoRustString(),
                cwd: "/tmp".intoRustString(),
                env: env,
                scrollback_lines: 0
            ))
    }

    private func makeRenderer() throws -> MetalRenderer {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return MetalRenderer(device: device)
    }

    // MARK: - Stalled link

    /// The motivating case: no tick has landed (display asleep, window
    /// fully occluded), so `draw(update:)` isn't draining anything. The
    /// pump must run the drain and leave `pendingFullRepaint` set —
    /// without the flag, the cells carried by the delta it threw away
    /// would never be repainted once the link resumes.
    func testStalledLinkDrainsAndFlagsAFullRepaint() throws {
        let renderer = try makeRenderer()
        renderer.attachSessionForTesting(try XCTUnwrap(makeSession()))
        renderer.lastDisplayLinkTick = 0
        renderer.now = { 10 }
        XCTAssertFalse(
            renderer.pendingFullRepaint,
            "a fresh renderer owes no repaint")

        renderer.pumpIfDisplayLinkStalled()

        XCTAssertTrue(
            renderer.pendingFullRepaint,
            "a stalled link must leave the next live tick a full repaint")
    }

    // MARK: - Healthy link

    /// A link pinned to its 30 Hz floor still ticks every ~33 ms, an
    /// order of magnitude inside the stall threshold. The pump has to
    /// stay out of its way: `take_frame_delta()` is destructive, so a
    /// pump that fired here would swallow the delta `draw(update:)` was
    /// about to paint — and the full-repaint flag is the only trace
    /// that would leave.
    func testHealthyLinkIsLeftAlone() throws {
        let renderer = try makeRenderer()
        renderer.attachSessionForTesting(try XCTUnwrap(makeSession()))
        renderer.lastDisplayLinkTick = 1_000
        renderer.now = { 1_000.01 }

        renderer.pumpIfDisplayLinkStalled()

        XCTAssertFalse(
            renderer.pendingFullRepaint,
            "a 10 ms-old tick is a live link; the pump must not run")

        // Control. Same renderer, same session, only the clock moved
        // past the threshold — so the assertion above says "the pump
        // declined", not "this renderer never raises the flag".
        renderer.now = {
            1_000 + MetalRenderer.displayLinkStallThresholdSec + 0.001
        }
        renderer.pumpIfDisplayLinkStalled()
        XCTAssertTrue(
            renderer.pendingFullRepaint,
            "past the threshold the very same renderer must pump")
    }

    // MARK: - No session

    /// The pump is armed from `windowChanged(window:)` and disarmed in
    /// `deinit`, so it can fire in the window where the renderer has
    /// dropped its session (`Cmd+R` rebuild, view left its window) but
    /// the timer has not yet been cancelled. The session guard comes
    /// before the stall check for exactly that: a stalled clock with no
    /// session must be inert, not a crash.
    func testMissingSessionIsInert() throws {
        let renderer = try makeRenderer()
        renderer.lastDisplayLinkTick = 0
        renderer.now = { 10 }
        XCTAssertNil(renderer.session, "no window, so no session")

        renderer.pumpIfDisplayLinkStalled()

        XCTAssertFalse(
            renderer.pendingFullRepaint,
            "nothing was drained, so nothing owes a repaint")

        // Control. The clock is still stalled, so the missing session
        // is the only thing that held the pump back.
        renderer.attachSessionForTesting(try XCTUnwrap(makeSession()))
        renderer.pumpIfDisplayLinkStalled()
        XCTAssertTrue(
            renderer.pendingFullRepaint,
            "the same stalled clock must pump once a session exists")
    }
}
