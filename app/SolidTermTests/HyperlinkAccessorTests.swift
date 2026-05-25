// M7-1 — OSC 8 hyperlink FFI accessor tests.
//
// Drives a /bin/cat-loopback session, feeds an `\e]8;;<URI>\e\\<text>\e]8;;\e\\`
// sequence into the PTY, and verifies `TerminalSession.hyperlink_at(row, col)`
// surfaces the URI plus the contiguous span the renderer needs for the
// underline overlay.

import XCTest

@testable import SolidTerm

final class HyperlinkAccessorTests: XCTestCase {

    private static func makeCatSession() -> TerminalSession {
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
            env: envVec,
            scrollback_lines: 0)
        return TerminalSession.new(config)
    }

    /// Out-of-range coordinates and blank cells return the empty-uri
    /// sentinel rather than crashing the bridge.
    func testHyperlinkAtReturnsEmptyForBlankAndOOB() {
        let session = Self.makeCatSession()
        let blank = session.hyperlink_at(0, 0)
        XCTAssertEqual(blank.uri.toString(), "", "blank cell carries no link")
        let oob = session.hyperlink_at(9999, 9999)
        XCTAssertEqual(
            oob.uri.toString(), "", "oob coordinates return the empty-uri sentinel")
    }

    /// `printf '\e]8;;https://example.com\e\\Click me\e]8;;\e\\\n'` — the
    /// canonical OSC 8 example from
    /// https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda.
    /// Every cell of "Click me" must report the URI; the span must
    /// cover all 8 columns of the run.
    func testHyperlinkAtRoundTripsOSC8Sequence() {
        let session = Self.makeCatSession()

        let payload = "\u{1b}]8;;https://example.com\u{1b}\\Click me\u{1b}]8;;\u{1b}\\\n"
        let key = KeyEvent(
            codepoint: 0, keycode: 0, text: payload.intoRustString(), action: 0)
        let mouse = MouseEvent(col: 0, row: 0, button: 0, action: 0)
        let event = InputEvent(kind: 0, key: key, mouse: mouse, modifiers: 0)
        session.send_input(event)

        let deadline = Date().addingTimeInterval(5.0)
        var found: HyperlinkHit?
        while Date() < deadline && found == nil {
            _ = session.take_frame_delta()
            outer: for r in UInt16(0)..<UInt16(2) {
                for c in UInt16(0)..<UInt16(80) {
                    let hit = session.hyperlink_at(r, c)
                    if hit.uri.toString() == "https://example.com" {
                        found = hit
                        break outer
                    }
                }
            }
            if found == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        guard let hit = found else {
            XCTFail("expected the OSC 8 URI to surface within 5s")
            return
        }
        XCTAssertEqual(hit.uri.toString(), "https://example.com")
        XCTAssertEqual(hit.span, 8, "span must cover all 8 cells of \"Click me\"")
    }
}
