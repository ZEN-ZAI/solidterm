// Pins the OSC 8 scheme-allowlist WIRING (commit 06a38b6) end-to-end:
// a remote-printed file:// hyperlink must produce no ⌘-hover, while
// https:// must.
//
// NSEvent mouse synthesis is blocked in headless XCTest (see
// SelectionInputTests' note), so the test calls
// `recomputeFileClickHover(at:modifiers:)` directly with a window
// point computed by `windowPoint(forRow:col:)`.

import AppKit
import XCTest

@testable import SolidTerm

final class Osc8HoverPolicyTests: XCTestCase {

    // MARK: - Helpers

    /// Verbatim from CopyPasteTests (~:823-834) — surface + titled NSWindow,
    /// contentView assignment wires the renderer (viewDidMoveToWindow drives
    /// session bring-up).
    private static func makeSurface() -> TerminalSurfaceView {
        let surface = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        // viewDidMoveToWindow drives the renderer's session bring-up;
        // attach to a host window so the renderer wires correctly.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentView = surface
        return surface
    }

    /// Feed an OSC 8 hyperlink carrying `payloadURI`, wait for it to surface
    /// on the grid, then invoke `recomputeFileClickHover` at the cell's
    /// window-coord midpoint and return the renderer's `linkHover` state.
    ///
    /// Returns `nil` if the hover produced no hit. Throws `XCTSkip` when
    /// the environment cannot complete the test (no Metal, session never
    /// arrived, or link never surfaced — all environmental, not policy
    /// failures).
    private func hoverProbe(payloadURI: String) throws -> MetalRenderer.LinkHover? {
        try XCTSkipUnless(
            MTLCreateSystemDefaultDevice() != nil,
            "Metal device unavailable in test environment")

        let surface = Self.makeSurface()
        defer {
            // Tear the host window down on every exit path (including
            // XCTSkip): window-ordering E2E tests (SearchPanelE2ETests)
            // run in this same process and are sensitive to stray
            // windows left in NSApp.windows.
            if let window = surface.window {
                window.isReleasedWhenClosed = false
                window.close()
            }
        }

        // Poll up to 5 s for session bring-up (viewDidMoveToWindow is
        // synchronous on this path, but the RunLoop spin is the contract
        // to guard against headless timing variance).
        let bringUpDeadline = Date().addingTimeInterval(5.0)
        while Date() < bringUpDeadline && surface.rendererForTesting.session == nil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        guard let session = surface.rendererForTesting.session else {
            throw XCTSkip(
                "session never arrived; headless session bring-up too slow in this environment"
            )
        }

        // The renderer's session runs the user's login shell, whose line
        // editor consumes raw ESC bytes as keystrokes instead of echoing
        // them (the /bin/cat echo trick from HyperlinkAccessorTests is
        // unavailable here — `MetalRenderer.session` is private(set)). So
        // TYPE a printf command and let the shell emit the OSC 8 sequence
        // on the output path: the typed characters below are
        //   printf '\e]8;;URI\e\\X\e]8;;\e\\\n'  + Enter
        // and printf turns the \e escapes into the real sequence.
        let payload =
            "printf '\\e]8;;\(payloadURI)\\e\\\\X\\e]8;;\\e\\\\\\n'\n"
        let key = KeyEvent(
            codepoint: 0,
            keycode: 0,
            text: payload.intoRustString(),
            action: 0)
        let mouse = MouseEvent(col: 0, row: 0, button: 0, action: 0)
        let event = InputEvent(kind: 0, key: key, mouse: mouse, modifiers: 0)
        session.send_input(event)

        // Poll ≤5 s (mirrors HyperlinkAccessorTests:60-71): drain
        // frame deltas each iteration and scan rows 0..<24 × cols 0..<80
        // for the target URI.
        let linkDeadline = Date().addingTimeInterval(5.0)
        var foundRow: UInt16?
        var foundCol: UInt16?
        outer: while Date() < linkDeadline {
            _ = session.take_frame_delta()
            for r in UInt16(0)..<UInt16(24) {
                for c in UInt16(0)..<UInt16(80) {
                    let hit = session.hyperlink_at(r, c)
                    if hit.uri.toString() == payloadURI {
                        foundRow = r
                        foundCol = c
                        break outer
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let r = foundRow, let c = foundCol else {
            throw XCTSkip(
                "OSC 8 link never surfaced; shell bring-up too slow in this environment")
        }

        // Compute the midpoint window coordinate for (r, c) using the
        // inverse helper and drive the hover policy directly.
        let pt = surface.windowPoint(forRow: r, col: c)
        surface.recomputeFileClickHover(at: pt, modifiers: [.command])
        return surface.rendererForTesting.linkHover
    }

    // MARK: - Tests

    /// A remote-printed `file://` hyperlink must produce no ⌘-hover:
    /// `file://` is outside the shared scheme allowlist, so ⌘-click must
    /// not arm.
    func testFileSchemeProducesNoHover() throws {
        let hover = try hoverProbe(payloadURI: "file:///etc/hosts")
        XCTAssertNil(
            hover,
            "file:// is outside the shared allowlist; ⌘-click must not arm")
    }

    /// A remote-printed `https://` hyperlink must produce a hover: positive
    /// control proving the probe itself works.
    func testHttpsSchemeProducesHover() throws {
        let hover = try hoverProbe(payloadURI: "https://example.com")
        XCTAssertNotNil(
            hover,
            "https:// is in the allowlist; ⌘-hover must arm")
    }

}
