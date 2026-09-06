// PG1 mouse reporting — xterm-compatible mouse-event encoder.
//
// When a TUI enables DEC 1000 / 1002 / 1003 mouse mode (typically via
// `printf '\e[?1000h'` from vim / less / htop / lazygit / tmux), the
// terminal emulator forwards each mouse event as an escape sequence
// instead of consuming it for selection. This file owns that encode
// + send path, plus the small helpers the AppKit handlers in
// `TerminalSurfaceView` use to decide whether to forward vs. handle.
//
// Encoding form:
//   - SGR-1006 (preferred, no 223-column limit):
//       press   → CSI < Cb;Cx;Cy M
//       release → CSI < Cb;Cx;Cy m
//   - Legacy X10 / 1005 (fallback, capped at column 223):
//       any     → CSI M Cb Cx Cy   (each byte + 32 offset)
//
// `Cb` (button + modifier + motion flags):
//   bits 0-1 — button index: 0 = left, 1 = middle, 2 = right
//   bit 2    — Shift
//   bit 3    — Meta / Alt
//   bit 4    — Ctrl
//   bit 5    — motion (drag) flag
//   bits 6+  — wheel encoded as button 64 (up) / 65 (down) / 66 / 67
//
// Coordinates are 1-based — column 0 / row 0 are reserved.

import AppKit

enum MouseReporting {

    /// True iff any mouse-report mode bit is set on the active
    /// session. The Swift mouse handlers gate their "skip selection"
    /// branch on this.
    static func modeActive(session: TerminalSession) -> Bool {
        session.mouse_mode_bits() != 0
    }

    /// Press / release event. `button` follows xterm convention —
    /// 0 = left, 1 = middle, 2 = right, 64+ = wheel.
    static func sendButtonEvent(
        session: TerminalSession,
        event: NSEvent,
        row: UInt16,
        col: UInt16,
        button: UInt8,
        pressed: Bool
    ) {
        let bits = session.mouse_mode_bits()
        let sgr = (bits & 0x08) != 0
        let cb = encodeCb(
            button: button,
            motion: false,
            modifiers: event.modifierFlags,
            release: !pressed && !sgr)
        let payload =
            sgr
            ? sgrFormat(cb: cb, row: row, col: col, pressed: pressed)
            : legacyFormat(cb: cb, row: row, col: col)
        send(session: session, payload: payload)
    }

    /// Drag-with-button-held / pure-motion event. `button` is the
    /// last-pressed mouse button (0 for left-drag); for pure-motion
    /// (DEC 1003) the caller still passes the most recent button or
    /// 3 (=release) per xterm convention. The motion-flag bit is
    /// always set here.
    static func sendMotionEvent(
        session: TerminalSession,
        event: NSEvent,
        row: UInt16,
        col: UInt16,
        button: UInt8
    ) {
        let bits = session.mouse_mode_bits()
        let sgr = (bits & 0x08) != 0
        let cb = encodeCb(
            button: button,
            motion: true,
            modifiers: event.modifierFlags,
            release: false)
        let payload =
            sgr
            ? sgrFormat(cb: cb, row: row, col: col, pressed: true)
            : legacyFormat(cb: cb, row: row, col: col)
        send(session: session, payload: payload)
    }

    // MARK: - Encoding internals

    private static func encodeCb(
        button: UInt8,
        motion: Bool,
        modifiers: NSEvent.ModifierFlags,
        release: Bool
    ) -> UInt8 {
        var cb: UInt8
        if release {
            // Legacy form: release-of-any-button = button index 3.
            cb = 3
        } else if button >= 64 {
            // Wheel: keep the full button code (64+).
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

    private static func sgrFormat(
        cb: UInt8, row: UInt16, col: UInt16, pressed: Bool
    ) -> String {
        // Coordinates are 1-based.
        let terminator: Character = pressed ? "M" : "m"
        return "\u{1B}[<\(cb);\(col + 1);\(row + 1)\(terminator)"
    }

    private static func legacyFormat(
        cb: UInt8, row: UInt16, col: UInt16
    ) -> String {
        // Each byte gets a +32 offset. Capped at column 223 in the
        // legacy form (255 - 32 = 223) — beyond that, the host should
        // request DECSET 1006 to switch to SGR encoding.
        let cbByte = UInt8(min(255, Int(cb) + 32))
        let cxByte = UInt8(min(255, Int(col) + 33))
        let cyByte = UInt8(min(255, Int(row) + 33))
        var bytes: [UInt8] = [0x1B, UInt8(ascii: "["), UInt8(ascii: "M")]
        bytes.append(cbByte)
        bytes.append(cxByte)
        bytes.append(cyByte)
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    private static func send(session: TerminalSession, payload: String) {
        guard !payload.isEmpty else { return }
        session.send_input(
            InputEventEncoder.makeKeyInputEvent(
                characters: payload, keycode: 0, modifiers: []))
    }
}
