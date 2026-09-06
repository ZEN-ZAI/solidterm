// A golden-hash lock over `BoxDrawing.rasterize` for every scalar that
// `BoxDrawing.handles` accepts (U+2500-U+259F today). `BoxDrawingTests`
// pins a dozen shapes by inspecting individual pixels; that is the
// readable contract, but it leaves ~150 codepoints of the 1,548-line
// `switch` unwitnessed. Restructuring that switch must not move a single
// pixel, so this file hashes the raster of every handled scalar at three
// cell geometries and compares against a checked-in table: any shape
// that changes names itself by codepoint, and all of them are reported
// in one run rather than one per re-run.
//
// The table is data, not a second implementation — it says nothing about
// what a glyph should look like, only that it looks the way it did when
// the table was cut. Regenerate deliberately with BOXDRAWING_REGEN=1 and
// read the diff: a hash that moves without an intended shape change is
// the drift this file exists to catch.

import Foundation
import XCTest

@testable import SolidTerm

final class BoxDrawingGoldenTests: XCTestCase {

    /// Cell geometries the table covers: a 1x cell, its 2x twin, and one
    /// tall enough to cross `rasterize`'s stroke-width threshold. The
    /// aspect-identical pair catches a shape that hard-codes a pixel index
    /// instead of deriving it from the cell metrics; 32x48 is the size
    /// `BoxDrawingTests.testHeavyHorizontalRule` already uses because it is
    /// where `light = max(1, heightPx / 24)` reaches 2 and `heavy` reaches
    /// 4 — without it every row in the table would be a light=1 raster and
    /// the scaled-stroke arithmetic would go unwitnessed.
    private static let cellSizes: [(width: Int, height: Int)] = [
        (10, 20), (20, 40), (32, 48),
    ]

    /// Every scalar `BoxDrawing.handles` accepts, discovered by asking it
    /// rather than by restating its ranges — a switch that gains or loses
    /// a codepoint shows up as a key-set difference, not as silence.
    private static let handledScalars: [Unicode.Scalar] = {
        var scalars: [Unicode.Scalar] = []
        for value in UInt32(0)...0x10_FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            if BoxDrawing.handles(scalar) { scalars.append(scalar) }
        }
        return scalars
    }()

    /// Read from the source tree, not from the test bundle: the
    /// regenerator below writes this exact path, so the table under test
    /// and the table under review are the same bytes.
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/boxdrawing-golden.json")

    // MARK: - The lock

    func testEveryHandledScalarMatchesItsGoldenHash() throws {
        let table = try Self.loadGoldenTable()
        var mismatches: [String] = []

        for size in Self.cellSizes {
            let cellKey = Self.cellKey(size)
            let expected = try XCTUnwrap(
                table[cellKey],
                "golden table has no entry for cell \(cellKey) — regenerate it")

            for scalar in Self.handledScalars {
                let codepoint = Self.codepointKey(scalar)
                guard
                    let bitmap = BoxDrawing.rasterize(
                        scalar: scalar, widthPx: size.width, heightPx: size.height)
                else {
                    mismatches.append("U+\(codepoint) \(cellKey): handled but rasterized to nil")
                    continue
                }
                guard bitmap.count == size.width * size.height else {
                    mismatches.append(
                        "U+\(codepoint) \(cellKey): \(bitmap.count) bytes, "
                            + "expected \(size.width * size.height)")
                    continue
                }
                guard let want = expected[codepoint] else {
                    mismatches.append("U+\(codepoint) \(cellKey): absent from the golden table")
                    continue
                }
                let actual = Self.hashKey(Self.fnv1a64(bitmap))
                if actual != want {
                    mismatches.append("U+\(codepoint) \(cellKey): \(want) -> \(actual)")
                }
            }
        }

        XCTAssertTrue(
            mismatches.isEmpty,
            """
            \(mismatches.count) box-drawing raster(s) changed:
            \(mismatches.joined(separator: "\n"))
            If the change is intended, regenerate with \
            TEST_RUNNER_BOXDRAWING_REGEN=1 and review the diff.
            """)
    }

    func testGoldenTableCoversExactlyTheHandledScalars() throws {
        let table = try Self.loadGoldenTable()
        let handled = Set(Self.handledScalars.map { Self.codepointKey($0) })
        var problems: [String] = []

        XCTAssertEqual(
            Set(table.keys), Set(Self.cellSizes.map { Self.cellKey($0) }),
            "golden table cell geometries drifted from the ones the test rasterizes")

        for (cellKey, hashes) in table.sorted(by: { $0.key < $1.key }) {
            let tabled = Set(hashes.keys)
            for missing in handled.subtracting(tabled).sorted() {
                problems.append("U+\(missing) \(cellKey): handled but absent from the table")
            }
            for extra in tabled.subtracting(handled).sorted() {
                problems.append("U+\(extra) \(cellKey): in the table but no longer handled")
            }
        }

        XCTAssertTrue(
            problems.isEmpty,
            """
            golden table and BoxDrawing.handles disagree on \(problems.count) codepoint(s):
            \(problems.joined(separator: "\n"))
            """)
    }

    // MARK: - Regenerator

    /// Rewrites `Fixtures/boxdrawing-golden.json` and prints the table as
    /// `0x2500: 0x…,` lines. Skipped unless BOXDRAWING_REGEN=1 is in the
    /// environment; under `xcodebuild test` pass it as
    /// TEST_RUNNER_BOXDRAWING_REGEN=1, which xcodebuild forwards to the
    /// test process with the prefix removed.
    func testRegenerateGoldenTable() throws {
        guard ProcessInfo.processInfo.environment["BOXDRAWING_REGEN"] == "1" else {
            throw XCTSkip(
                "set TEST_RUNNER_BOXDRAWING_REGEN=1 to rewrite \(Self.fixtureURL.path)")
        }

        var cells: [(key: String, rows: [(codepoint: String, hash: String)])] = []
        for size in Self.cellSizes {
            let cellKey = Self.cellKey(size)
            var rows: [(codepoint: String, hash: String)] = []
            print("// cell \(cellKey)")
            for scalar in Self.handledScalars {
                let bitmap = try XCTUnwrap(
                    BoxDrawing.rasterize(
                        scalar: scalar, widthPx: size.width, heightPx: size.height))
                let row = (Self.codepointKey(scalar), Self.hashKey(Self.fnv1a64(bitmap)))
                rows.append(row)
                print("0x\(row.0): \(row.1),")
            }
            cells.append((cellKey, rows))
        }

        // Hand-rolled so the rows stay in codepoint order. JSONSerialization's
        // .sortedKeys compares numerically, which interleaves "250A" before
        // "2500" and makes a drift diff unreadable — the one thing this table
        // is for.
        var json = "{\n  \"cells\": [\n"
        for (index, cell) in cells.enumerated() {
            let rows = cell.rows.map { "        \"\($0.codepoint)\": \"\($0.hash)\"" }
            json += "    {\n      \"cell\": \"\(cell.key)\",\n      \"hashes\": {\n"
            json += rows.joined(separator: ",\n") + "\n      }\n"
            json += index == cells.count - 1 ? "    }\n" : "    },\n"
        }
        json += "  ]\n}\n"

        try FileManager.default.createDirectory(
            at: Self.fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: Self.fixtureURL, atomically: true, encoding: .utf8)
        print("wrote \(Self.fixtureURL.path)")
    }

    // MARK: - Helpers

    /// FNV-1a 64: one multiply and one xor per byte, no dependencies, and
    /// stable across processes — a cryptographic digest would buy nothing
    /// here beyond a slower test.
    private static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    private static func cellKey(_ size: (width: Int, height: Int)) -> String {
        "\(size.width)x\(size.height)"
    }

    private static func codepointKey(_ scalar: Unicode.Scalar) -> String {
        String(format: "%04X", scalar.value)
    }

    private static func hashKey(_ hash: UInt64) -> String {
        String(format: "0x%016llx", hash)
    }

    private static func loadGoldenTable() throws -> [String: [String: String]] {
        let data = try XCTUnwrap(
            try? Data(contentsOf: fixtureURL),
            "missing golden table at \(fixtureURL.path) — regenerate it")
        let root = try JSONSerialization.jsonObject(with: data)
        let cells = try XCTUnwrap(
            (root as? [String: Any])?["cells"] as? [[String: Any]],
            "golden table is not {\"cells\": [...]}")

        var table: [String: [String: String]] = [:]
        for cell in cells {
            let key = try XCTUnwrap(cell["cell"] as? String, "cell entry without a \"cell\" key")
            table[key] = try XCTUnwrap(
                cell["hashes"] as? [String: String], "cell \(key) without string hashes")
        }
        return table
    }
}
