// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// M7-2 — wire-format byte-level coverage for the
// `TerminalSession.search` payload, matching the Rust-side
// `SearchMatchWire` layout (8 bytes: i32 line, u16 col, u16 len).

import XCTest

@testable import SolidTerm

final class SearchMatchDecodingTests: XCTestCase {

    func testEmptyPayloadDecodesToEmptyArray() throws {
        let out = try SearchMatchDecoding.decode([UInt8]())
        XCTAssertEqual(out, [])
    }

    func testMalformedPayloadThrows() {
        // 7 bytes — not a multiple of wireSize (8).
        XCTAssertThrowsError(
            try SearchMatchDecoding.decode([UInt8](repeating: 0, count: 7))
        ) { err in
            guard case SearchMatchDecoding.DecodeError.malformedPayload(7) = err
            else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }

    func testSingleRecordRoundTrip() throws {
        // line = -3, col = 5, len = 7
        let bytes: [UInt8] = [
            0xFD, 0xFF, 0xFF, 0xFF,  // i32 -3 (little-endian)
            0x05, 0x00,  // u16 5
            0x07, 0x00,  // u16 7
        ]
        let out = try SearchMatchDecoding.decode(bytes)
        XCTAssertEqual(out, [SearchMatchSwift(line: -3, col: 5, len: 7)])
    }

    func testMultipleRecordsAreOrdered() throws {
        let bytes: [UInt8] = [
            // record 0: line=0, col=0, len=3
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00,
            // record 1: line=1, col=10, len=4
            0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x04, 0x00,
        ]
        let out = try SearchMatchDecoding.decode(bytes)
        XCTAssertEqual(
            out,
            [
                SearchMatchSwift(line: 0, col: 0, len: 3),
                SearchMatchSwift(line: 1, col: 10, len: 4),
            ])
    }
}
