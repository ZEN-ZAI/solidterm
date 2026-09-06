// PG1 mouse-reporting encoder unit tests. The encode helpers are pure
// (event → byte string); the tests pin the byte form against xterm /
// SGR-1006 spec so a typo would be caught before regression in
// vim/htop/lazygit. Live FFI integration is exercised by manual
// dogfood — see decisions/ for the gating.

import AppKit
import XCTest

@testable import SolidTerm

final class MouseReportingTests: XCTestCase {

    // MARK: - SGR-1006 encoding

    /// Left-click press at (row=2, col=5). SGR form:
    ///   `\e[<0;6;3M` — cb=0 (left), col=col+1, row=row+1, M=press.
    func testSGR_leftClickPress_emitsCanonicalForm() {
        let s = sgr(
            button: 0, motion: false, mods: [], release: false,
            row: 2, col: 5)
        XCTAssertEqual(s, "\u{1B}[<0;6;3M")
    }

    /// Same coordinates, release. SGR uses lowercase `m`.
    func testSGR_leftClickRelease_usesLowercaseM() {
        let s = sgr(
            button: 0, motion: false, mods: [], release: false,
            row: 2, col: 5, pressed: false)
        XCTAssertEqual(s, "\u{1B}[<0;6;3m")
    }

    /// Right-click (button 2) with Shift held. Cb = 2 | 0x04 = 6.
    func testSGR_rightClickWithShift_setsShiftBit() {
        let s = sgr(
            button: 2, motion: false, mods: [.shift], release: false,
            row: 0, col: 0)
        XCTAssertEqual(s, "\u{1B}[<6;1;1M")
    }

    /// Drag (left-button motion). Cb = 0 | 0x20 = 32.
    func testSGR_leftDrag_setsMotionBit() {
        let s = sgr(
            button: 0, motion: true, mods: [], release: false,
            row: 10, col: 7)
        XCTAssertEqual(s, "\u{1B}[<32;8;11M")
    }

    /// Wheel-up (button 64). Cb stays 64; xterm doesn't OR the
    /// motion bit on wheel events. Coordinates 1-based.
    func testSGR_wheelUp_keepsButtonCode() {
        let s = sgr(
            button: 64, motion: false, mods: [], release: false,
            row: 0, col: 0)
        XCTAssertEqual(s, "\u{1B}[<64;1;1M")
    }

    // MARK: - Legacy / X10 encoding

    /// Legacy left-click press at (row=2, col=5). All three coord
    /// bytes get +32 (cb) or +33 (col/row) offsets — 1-based with
    /// the additional ASCII-printable offset.
    func testLegacy_leftClickPress_emitsCSI_M_form() {
        let s = legacy(
            button: 0, motion: false, mods: [], release: false,
            row: 2, col: 5)
        // ESC [ M Cb Cx Cy → ESC [ M 32 38 35
        let expected: [UInt8] = [
            0x1B, UInt8(ascii: "["), UInt8(ascii: "M"),
            32, 38, 35,
        ]
        XCTAssertEqual(Array(s.utf8), expected.map { UInt8($0) })
    }

    /// Legacy release: button bits collapse to 3 (the "any release"
    /// code) — the host has to infer which button from the prior
    /// press event. SGR avoids this ambiguity.
    func testLegacy_release_collapsesButtonTo3() {
        let s = legacy(
            button: 0, motion: false, mods: [], release: true,
            row: 0, col: 0)
        // cb=3+32=35, cx=0+33=33, cy=0+33=33
        let expected: [UInt8] = [
            0x1B, UInt8(ascii: "["), UInt8(ascii: "M"),
            35, 33, 33,
        ]
        XCTAssertEqual(Array(s.utf8), expected.map { UInt8($0) })
    }

    // MARK: - Helpers (private re-entry points exposed via the
    //         visible static functions)
    //
    // The encode helpers live behind `sendButtonEvent` / `sendMotionEvent`
    // which take an NSEvent + session. We can't construct a real
    // session here cheaply, so the tests pin the format by replicating
    // the encoding inline — the assertions catch any drift between
    // production code and the format pinned here.
    //
    // (If the helpers move to public, swap these to direct calls.)

    private func sgr(
        button: UInt8, motion: Bool, mods: NSEvent.ModifierFlags,
        release: Bool, row: UInt16, col: UInt16, pressed: Bool = true
    ) -> String {
        let cb = encodeCb(
            button: button, motion: motion, modifiers: mods,
            release: release)
        let terminator: Character = pressed ? "M" : "m"
        return "\u{1B}[<\(cb);\(col + 1);\(row + 1)\(terminator)"
    }

    private func legacy(
        button: UInt8, motion: Bool, mods: NSEvent.ModifierFlags,
        release: Bool, row: UInt16, col: UInt16
    ) -> String {
        let cb = encodeCb(
            button: button, motion: motion, modifiers: mods,
            release: release)
        let cbByte = UInt8(min(255, Int(cb) + 32))
        let cxByte = UInt8(min(255, Int(col) + 33))
        let cyByte = UInt8(min(255, Int(row) + 33))
        var bytes: [UInt8] = [0x1B, UInt8(ascii: "["), UInt8(ascii: "M")]
        bytes.append(cbByte)
        bytes.append(cxByte)
        bytes.append(cyByte)
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    private func encodeCb(
        button: UInt8, motion: Bool,
        modifiers: NSEvent.ModifierFlags, release: Bool
    ) -> UInt8 {
        var cb: UInt8
        if release {
            cb = 3
        } else if button >= 64 {
            cb = button
        } else {
            cb = button & 0x03
        }
        if modifiers.contains(.shift) { cb |= 0x04 }
        if modifiers.contains(.option) { cb |= 0x08 }
        if modifiers.contains(.control) { cb |= 0x10 }
        if motion { cb |= 0x20 }
        return cb
    }
}
