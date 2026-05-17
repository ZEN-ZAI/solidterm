// Implements spec/ffi-boundary.md round-trip contract for the renderer
// data types (CellDelta / FrameDelta / BlockDelta / InputEvent /
// SessionConfig). Exercises the swift-bridge surface end-to-end:
// Swift constructs a value, hands it to Rust via an `echo_*` function,
// and asserts the returned value is structurally identical.

import XCTest

@testable import SolidTerm

final class FFIDataTypeTests: XCTestCase {

    // MARK: - Helpers

    private func makeBytes(_ bytes: [UInt8]) -> RustVec<UInt8> {
        let v = RustVec<UInt8>()
        for b in bytes { v.push(value: b) }
        return v
    }

    private func bytes(from vec: RustVec<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        for i in 0..<UInt(vec.len()) {
            if let b = vec.get(index: i) { out.append(b) }
        }
        return out
    }

    private func makeCell(
        row: UInt16, col: UInt16, grapheme: [UInt8],
        fg: UInt32, bg: UInt32, attrs: UInt16, width: UInt8
    ) -> CellDelta {
        CellDelta(
            row: row, col: col, grapheme: makeBytes(grapheme),
            fg: fg, bg: bg, attrs: attrs, width: width
        )
    }

    // MARK: - CellDelta

    func testCellDeltaRoundTrip() {
        let original = makeCell(
            row: 5, col: 17, grapheme: Array("A".utf8),
            fg: 0xFFFF_FFFF, bg: 0x0000_00FF,
            attrs: 0b0000_0001, width: 1
        )
        let echoed = echo_cell_delta(original)
        XCTAssertEqual(echoed.row, 5)
        XCTAssertEqual(echoed.col, 17)
        XCTAssertEqual(bytes(from: echoed.grapheme), Array("A".utf8))
        XCTAssertEqual(echoed.fg, 0xFFFF_FFFF)
        XCTAssertEqual(echoed.bg, 0x0000_00FF)
        XCTAssertEqual(echoed.attrs, 0b0000_0001)
        XCTAssertEqual(echoed.width, 1)
    }

    func testCellDeltaMultiByteGrapheme() {
        let glyph = Array("字".utf8)  // 3-byte CJK
        let original = makeCell(
            row: 0, col: 0, grapheme: glyph,
            fg: 0, bg: 0, attrs: 0, width: 2
        )
        let echoed = echo_cell_delta(original)
        XCTAssertEqual(bytes(from: echoed.grapheme), glyph)
        XCTAssertEqual(echoed.width, 2)
    }

    // MARK: - FrameDelta

    func testFrameDeltaRoundTripWithCellsPayload() throws {
        // `cells: Vec<u8>` carries CellDeltaWire records (32 bytes each)
        // with the layout from spec/ffi-boundary.md, encoded by
        // FrameDeltaDecoding.encodeCells / decoded by .decodeCells.
        let cells: [CellDeltaSwift] = [
            CellDeltaSwift(
                row: 0, col: 0, grapheme: padded(Array("X".utf8)),
                fg: 0x1122_3344, bg: 0x5566_7788, attrs: 0, width: 1
            ),
            CellDeltaSwift(
                row: 0, col: 1, grapheme: padded(Array("Y".utf8)),
                fg: 0xAABB_CCDD, bg: 0x9988_7766, attrs: 0b0010, width: 1
            ),
        ]
        let payload = FrameDeltaDecoding.encodeCells(cells)
        XCTAssertEqual(payload.count, 2 * FrameDeltaDecoding.cellWireSize)

        let cursor = CursorState(row: 5, col: 18, shape: 1, blink: true, hidden: false)
        let frame = FrameDelta(
            cells: makeBytes(payload),
            cursor: cursor,
            scroll_top: 42, scroll_total: 1024, pane_mode: 0
        )
        let echoed = echo_frame_delta(frame)

        XCTAssertEqual(echoed.cursor.row, 5)
        XCTAssertEqual(echoed.cursor.col, 18)
        XCTAssertEqual(echoed.cursor.shape, 1)
        XCTAssertTrue(echoed.cursor.blink)
        XCTAssertFalse(echoed.cursor.hidden)
        XCTAssertEqual(echoed.scroll_top, 42)
        XCTAssertEqual(echoed.scroll_total, 1024)
        XCTAssertEqual(echoed.pane_mode, 0)

        let decoded = try FrameDeltaDecoding.decodeCells(echoed.cells)
        XCTAssertEqual(decoded, cells)
    }

    func testFrameDeltaCellsPayloadEmpty() throws {
        let cursor = CursorState(row: 0, col: 0, shape: 0, blink: false, hidden: true)
        let frame = FrameDelta(
            cells: makeBytes([]),
            cursor: cursor,
            scroll_top: 0, scroll_total: 0, pane_mode: 1
        )
        let echoed = echo_frame_delta(frame)
        let decoded = try FrameDeltaDecoding.decodeCells(echoed.cells)
        XCTAssertTrue(decoded.isEmpty)
    }

    func testFrameDeltaCellsPayloadMultiByteGrapheme() throws {
        let glyph = Array("字".utf8)  // 3 bytes
        let cells: [CellDeltaSwift] = [
            CellDeltaSwift(
                row: 0, col: 0, grapheme: padded(glyph),
                fg: 0, bg: 0, attrs: 0, width: 2
            )
        ]
        let payload = FrameDeltaDecoding.encodeCells(cells)
        let frame = FrameDelta(
            cells: makeBytes(payload),
            cursor: CursorState(row: 0, col: 0, shape: 0, blink: false, hidden: false),
            scroll_top: 0, scroll_total: 0, pane_mode: 0
        )
        let echoed = echo_frame_delta(frame)
        let decoded = try FrameDeltaDecoding.decodeCells(echoed.cells)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(Array(decoded[0].grapheme.prefix(glyph.count)), glyph)
        XCTAssertEqual(decoded[0].width, 2)
    }

    func testFrameDeltaCellsPayloadRejectsMisaligned() {
        // 23 bytes is not a multiple of the 24-byte record size.
        let bogus = [UInt8](repeating: 0, count: 23)
        XCTAssertThrowsError(try FrameDeltaDecoding.decodeCells(bogus)) { err in
            guard case FrameDeltaDecoding.DecodeError.malformedPayload = err else {
                XCTFail("expected malformedPayload, got \(err)")
                return
            }
        }
    }

    // MARK: - InputEvent

    func testInputEventKeyRoundTrip() {
        // KeyEvent.text is `RustString` post-#16-perf (was `Vec<u8>`).
        // Single-FFI-call construction via `String.intoRustString()`.
        let key = KeyEvent(
            codepoint: UInt32(Character("a").asciiValue!),
            keycode: 0,
            text: "a".intoRustString(),
            action: 0
        )
        let mouse = MouseEvent(col: 0, row: 0, button: 0, action: 0)
        let event = InputEvent(kind: 0, key: key, mouse: mouse, modifiers: 0)
        let echoed = echo_input_event(event)

        XCTAssertEqual(echoed.kind, 0)
        XCTAssertEqual(echoed.key.codepoint, 0x61)
        XCTAssertEqual(echoed.key.keycode, 0)
        XCTAssertEqual(echoed.key.text.toString(), "a")
        XCTAssertEqual(echoed.key.action, 0)
        XCTAssertEqual(echoed.modifiers, 0)
    }

    func testInputEventMouseRoundTrip() {
        let key = KeyEvent(
            codepoint: 0, keycode: 0, text: "".intoRustString(), action: 0)
        let mouse = MouseEvent(col: 42, row: 7, button: 1, action: 2)
        let event = InputEvent(
            kind: 1, key: key, mouse: mouse,
            modifiers: 0b0000_0010  // ctrl
        )
        let echoed = echo_input_event(event)

        XCTAssertEqual(echoed.kind, 1)
        XCTAssertEqual(echoed.mouse.col, 42)
        XCTAssertEqual(echoed.mouse.row, 7)
        XCTAssertEqual(echoed.mouse.button, 1)
        XCTAssertEqual(echoed.mouse.action, 2)
        XCTAssertEqual(echoed.modifiers, 0b0000_0010)
    }

    // MARK: - SessionConfig

    func testSessionConfigRoundTripWithEnvPayload() {
        // `env: Vec<u8>` is `KEY=VALUE\n`-joined UTF-8 bytes. Swift
        // encodes via EnvEncoding.encode; Rust decodes via decode_env.
        let envPairs: [(String, String)] = [
            ("TERM", "xterm-256color"),
            ("LANG", "en_US.UTF-8"),
            ("PATH", "/usr/local/bin:/usr/bin:/bin"),
        ]
        let envBytes = EnvEncoding.encode(envPairs)
        let config = SessionConfig(
            rows: 40, cols: 120, pixel_w: 1440, pixel_h: 900,
            command: "/bin/zsh".intoRustString(),
            cwd: "/Users/zen".intoRustString(),
            env: makeBytes(envBytes)
        )
        let echoed = echo_session_config(config)

        XCTAssertEqual(echoed.rows, 40)
        XCTAssertEqual(echoed.cols, 120)
        XCTAssertEqual(echoed.pixel_w, 1440)
        XCTAssertEqual(echoed.pixel_h, 900)
        XCTAssertEqual(echoed.command.toString(), "/bin/zsh")
        XCTAssertEqual(echoed.cwd.toString(), "/Users/zen")
        XCTAssertEqual(bytes(from: echoed.env), envBytes)

        // Decoding the echoed bytes back to a string proves the wire
        // format survived round-trip; the engine-side decoder lives in
        // Rust (decode_env in bridge.rs) and is exercised by Rust tests.
        let echoedString = String(decoding: bytes(from: echoed.env), as: UTF8.self)
        XCTAssertTrue(echoedString.contains("TERM=xterm-256color\n"))
        XCTAssertTrue(echoedString.contains("LANG=en_US.UTF-8\n"))
    }

    func testSessionConfigEnvPayloadEmpty() {
        let config = SessionConfig(
            rows: 24, cols: 80, pixel_w: 0, pixel_h: 0,
            command: "/bin/sh".intoRustString(),
            cwd: "/tmp".intoRustString(),
            env: makeBytes([])
        )
        let echoed = echo_session_config(config)
        XCTAssertEqual(echoed.env.len(), 0)
    }

    // MARK: - Helpers (cells)

    /// Right-pad a UTF-8 byte sequence to exactly 8 bytes (the wire
    /// `grapheme` field width), zero-filling the tail. Mirrors what
    /// `CellDeltaWire::new` does on the Rust side.
    private func padded(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        if out.count > 16 {
            out = Array(out.prefix(16))
        } else {
            while out.count < 16 { out.append(0) }
        }
        return out
    }
}
