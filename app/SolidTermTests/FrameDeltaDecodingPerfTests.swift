// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Performance regression guard for `FrameDeltaDecoding.decodeCells(RustVec<UInt8>)`.
// The decoder sits on the renderer hot path (CAMetalDisplayLink → take_frame_delta
// → decodeCells), so it MUST avoid per-byte FFI calls. A previous implementation
// iterated `vec.get(index:)` byte-by-byte, costing ~46k swift-bridge calls per
// frame for a typical 80×24 viewport — catastrophic at 120 Hz. This test measures
// 100 decode passes of a 1920-cell payload and asserts a generous ceiling so any
// future regression to an O(n)-FFI loop is caught loudly. Tighter budgets land
// alongside #8 (typing-to-pixel measurement).

import XCTest

@testable import SolidTerm

final class FrameDeltaDecodingPerfTests: XCTestCase {

    private static let cellsPerFrame = 80 * 24  // 1,920 cells (M1 viewport baseline)
    private static let iterations = 100
    // The regression this guards is a decoder that reads the wire one byte at a
    // time across the FFI boundary. Rather than assume what that costs, the test
    // performs exactly that traversal on the same payload and machine, and
    // requires a real decode pass to come in under a fraction of it. A fixed
    // wall-clock ceiling could not: 1.5 s held on a developer Mac and failed at
    // 2.9 s on a shared macos-14 runner, which said nothing about the decoder.
    // Measured here: a pass costs about half a traversal, and a decoder that
    // went back to per-byte reads would pay the traversal on top of its own
    // work — three times the current cost. One traversal sits between the two.
    private static let perByteFraction: Double = 1.0

    /// Synthesizes a 1920-cell wire payload via the symmetric `encodeCells` so
    /// the byte content is realistic but deterministic.
    private func samplePayload() -> [UInt8] {
        let cells = (0..<Self.cellsPerFrame).map { i -> CellDeltaSwift in
            CellDeltaSwift(
                row: UInt16(i / 80),
                col: UInt16(i % 80),
                grapheme: Array("A".utf8) + Array(repeating: UInt8(0), count: 15),
                fg: 0x0DCD_D6D6,
                bg: 0x100D_0C00,
                attrs: 0,
                width: 1
            )
        }
        return FrameDeltaDecoding.encodeCells(cells)
    }

    /// Builds a `RustVec<UInt8>` from raw bytes. Population uses `push(value:)`
    /// per byte — slow, but only runs once during setup, not inside the
    /// measurement window.
    private func rustVec(from bytes: [UInt8]) -> RustVec<UInt8> {
        let v = RustVec<UInt8>()
        for b in bytes { v.push(value: b) }
        return v
    }

    /// One traversal of the vec through `get(index:)`, the shape the decoder
    /// must never go back to: an FFI call per byte. Timed on the machine running
    /// the test so the budget below tracks the hardware instead of a constant.
    private func perByteTraversalSeconds(_ vec: RustVec<UInt8>, count: Int) -> Double {
        let start = DispatchTime.now()
        var sum: UInt64 = 0
        for i in 0..<count { sum &+= UInt64(vec.get(index: UInt(i)) ?? 0) }
        let seconds =
            Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        XCTAssertGreaterThan(sum, 0, "the traversal must actually read the payload")
        return seconds
    }

    func testDecodeCellsRustVecHotPathBudget() throws {
        let payload = samplePayload()
        let vec = rustVec(from: payload)
        let perByteSeconds = perByteTraversalSeconds(vec, count: payload.count)

        let start = DispatchTime.now()
        for _ in 0..<Self.iterations {
            let cells = try FrameDeltaDecoding.decodeCells(vec)
            XCTAssertEqual(cells.count, Self.cellsPerFrame)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        let perPass = elapsed / Double(Self.iterations)

        // Log the measurement for #8's eventual baseline and surface it in the
        // xcresult bundle so the CI run records the wall-clock cost.
        let budget = perByteSeconds * Self.perByteFraction
        print(
            "decodeCells(RustVec<UInt8>) ×\(Self.iterations) over \(Self.cellsPerFrame) cells: "
                + String(format: "%.4f", elapsed * 1000) + " ms total, "
                + String(format: "%.4f", perPass * 1000) + " ms per pass; one per-byte "
                + "get(index:) traversal of \(payload.count) bytes: "
                + String(format: "%.4f", perByteSeconds * 1000) + " ms")
        XCTAssertLessThan(
            perPass, budget,
            "a decode pass took " + String(format: "%.2f", perPass * 1000)
                + " ms, past the " + String(format: "%.2f", budget * 1000)
                + " ms allowed by this machine's own per-byte get(index:) traversal "
                + "(" + String(format: "%.2f", perByteSeconds * 1000) + " ms) — check for "
                + "re-introduction of an O(n) per-byte FFI loop")
    }
}
