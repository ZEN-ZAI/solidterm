// Coverage for `BoxDrawing.swift`. Pins the procedural rasterizer's
// observable contracts: range membership, pixel-exact line geometry,
// block-element extents, and — load-bearing — the cross-cell
// connection invariant that the entire renderer change exists to
// fix. The "rules connect" test (test 8) is the architectural
// regression guard: if `hLine`'s right-edge boundary regresses to
// `widthPx - 1` instead of `widthPx`, two adjacent cells stop
// joining and Claude Code's TUI rules render dashed again.

import XCTest

@testable import SolidTerm

final class BoxDrawingTests: XCTestCase {

    // MARK: - Range membership

    func testHandlesBoxDrawingRange() {
        XCTAssertTrue(BoxDrawing.handles(Unicode.Scalar(0x2500)!))  // ─
        XCTAssertTrue(BoxDrawing.handles(Unicode.Scalar(0x257F)!))  // ╿
        XCTAssertTrue(BoxDrawing.handles(Unicode.Scalar(0x2580)!))  // ▀
        XCTAssertTrue(BoxDrawing.handles(Unicode.Scalar(0x2588)!))  // █
        XCTAssertTrue(BoxDrawing.handles(Unicode.Scalar(0x259F)!))  // ▟
        XCTAssertFalse(BoxDrawing.handles(Unicode.Scalar("A")))
        XCTAssertFalse(BoxDrawing.handles(Unicode.Scalar(0x24FF)!))  // before range
        // U+25A0 falls in the gap between box drawing and block elements.
        XCTAssertFalse(BoxDrawing.handles(Unicode.Scalar(0x25A0)!))
        XCTAssertFalse(BoxDrawing.handles(Unicode.Scalar(0x25A1)!))
        XCTAssertFalse(BoxDrawing.handles(Unicode.Scalar(0x25FF)!))  // after range
        XCTAssertFalse(BoxDrawing.handles(Unicode.Scalar(0x2600)!))
    }

    func testRasterizeReturnsNilForUnhandledScalar() {
        let bitmap = BoxDrawing.rasterize(
            scalar: Unicode.Scalar("A"), widthPx: 16, heightPx: 24)
        XCTAssertNil(bitmap)
    }

    // MARK: - Light strokes

    func testRasterizeHorizontalLightRule() throws {
        let bitmap = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x2500)!,  // ─
                widthPx: 16, heightPx: 24))
        XCTAssertEqual(bitmap.count, 16 * 24)

        // y=12 (cell midline) is fully opaque across all 16 columns.
        for x in 0..<16 {
            XCTAssertEqual(
                bitmap[12 * 16 + x], 0xFF,
                "U+2500 row 12 col \(x) expected opaque")
        }
        // Every other row is fully zero.
        for y in 0..<24 where y != 12 {
            for x in 0..<16 {
                XCTAssertEqual(
                    bitmap[y * 16 + x], 0,
                    "U+2500 row \(y) col \(x) expected blank (off-axis)")
            }
        }
    }

    func testRasterizeVerticalLightRule() throws {
        let bitmap = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x2502)!,  // │
                widthPx: 16, heightPx: 24))
        XCTAssertEqual(bitmap.count, 16 * 24)

        // x=8 (cell midcol) is fully opaque across all 24 rows.
        for y in 0..<24 {
            XCTAssertEqual(
                bitmap[y * 16 + 8], 0xFF,
                "U+2502 row \(y) col 8 expected opaque")
        }
        // Every other column is fully zero.
        for y in 0..<24 {
            for x in 0..<16 where x != 8 {
                XCTAssertEqual(
                    bitmap[y * 16 + x], 0,
                    "U+2502 row \(y) col \(x) expected blank (off-axis)")
            }
        }
    }

    // MARK: - Heavy + double strokes

    func testHeavyHorizontalRule() throws {
        // Use a larger cell so the heavy / light distinction is
        // visible: at heightPx=48 light=2, heavy=4. Counting opaque
        // rows lets us assert "thicker than light" without coupling
        // to exact stroke positions.
        let light = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x2500)!,
                widthPx: 32, heightPx: 48))
        let heavy = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x2501)!,
                widthPx: 32, heightPx: 48))

        let lightOpaqueRows = (0..<48).filter { y in
            (0..<32).allSatisfy { x in light[y * 32 + x] == 0xFF }
        }.count
        let heavyOpaqueRows = (0..<48).filter { y in
            (0..<32).allSatisfy { x in heavy[y * 32 + x] == 0xFF }
        }.count

        XCTAssertGreaterThan(
            heavyOpaqueRows, lightOpaqueRows,
            "U+2501 heavy stroke must be thicker than U+2500 light")
        XCTAssertGreaterThanOrEqual(heavyOpaqueRows, lightOpaqueRows * 2)
    }

    func testDoubleHorizontalRule() throws {
        let bitmap = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x2550)!,  // ═
                widthPx: 16, heightPx: 24))

        // Two parallel strokes flanking the midline with at least
        // one fully-blank row between them.
        let opaqueRows = (0..<24).filter { y in
            (0..<16).allSatisfy { x in bitmap[y * 16 + x] == 0xFF }
        }
        XCTAssertEqual(
            opaqueRows.count, 2,
            "U+2550 must paint exactly two opaque rows; got \(opaqueRows)")
        XCTAssertGreaterThanOrEqual(
            opaqueRows[1] - opaqueRows[0], 2,
            "gap between strokes must be at least one blank row")

        // The gap rows themselves are fully zero across the cell.
        for y in (opaqueRows[0] + 1)..<opaqueRows[1] {
            for x in 0..<16 {
                XCTAssertEqual(bitmap[y * 16 + x], 0)
            }
        }
    }

    // MARK: - Corners + crosses

    func testRasterizeLowerLeftCorner() throws {
        // U+2514 └ — light up + right.
        let bitmap = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x2514)!,
                widthPx: 16, heightPx: 24))

        // Vertical stroke at col 8 reaches from y=0 down through the
        // join at y=12.
        for y in 0...12 {
            XCTAssertEqual(
                bitmap[y * 16 + 8], 0xFF,
                "U+2514 vertical at row \(y) col 8")
        }
        // Below y=12 the vertical stroke does NOT continue (this is
        // an "up + right" corner, not a vertical or cross).
        for y in 13..<24 {
            XCTAssertEqual(
                bitmap[y * 16 + 8], 0,
                "U+2514 col 8 row \(y) expected blank (no down-stem)")
        }
        // Horizontal stroke at row 12 reaches from col 8 to col 15.
        for x in 8..<16 {
            XCTAssertEqual(
                bitmap[12 * 16 + x], 0xFF,
                "U+2514 horizontal at row 12 col \(x)")
        }
        // Left of col 8 the horizontal stroke does NOT continue.
        for x in 0..<8 {
            XCTAssertEqual(
                bitmap[12 * 16 + x], 0,
                "U+2514 row 12 col \(x) expected blank (no left-stem)")
        }
    }

    func testRasterizeCross() throws {
        // U+253C ┼ — light vertical + horizontal.
        let bitmap = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x253C)!,
                widthPx: 16, heightPx: 24))

        // Horizontal at row 12 across all 16 columns.
        for x in 0..<16 {
            XCTAssertEqual(
                bitmap[12 * 16 + x], 0xFF,
                "U+253C horizontal at col \(x)")
        }
        // Vertical at col 8 across all 24 rows.
        for y in 0..<24 {
            XCTAssertEqual(
                bitmap[y * 16 + 8], 0xFF,
                "U+253C vertical at row \(y)")
        }
    }

    // MARK: - Cross-cell connection invariant

    func testHorizontalRulesConnectAcrossCells() throws {
        // The architectural regression guard: U+2500 painted at two
        // adjacent cells (concatenated side-by-side) MUST produce an
        // unbroken horizontal line at the midrow. The bug this entire
        // change fixes is "Menlo's U+2500 glyph stops short of the
        // cell advance, leaving a 1-px gap at every cell boundary".
        // If `hLine`'s right-edge bound regresses from `widthPx`
        // (the half-open `[x0, x1)` upper bound, painting through
        // `widthPx - 1`) to `widthPx - 1` (painting through
        // `widthPx - 2`), the very last column of every cell goes
        // unpainted and this test catches it.
        let cellW = 16
        let cellH = 24
        let bitmap = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x2500)!,
                widthPx: cellW, heightPx: cellH))

        // Synthesize the side-by-side concatenation of two adjacent
        // cells at the row-12 midline.
        var concatenated = [UInt8](repeating: 0, count: cellW * 2)
        for x in 0..<cellW {
            concatenated[x] = bitmap[12 * cellW + x]
            concatenated[cellW + x] = bitmap[12 * cellW + x]
        }
        // Every column across the concatenation is opaque — no gap
        // at the boundary (col cellW-1 OR col cellW).
        for x in 0..<(cellW * 2) {
            XCTAssertEqual(
                concatenated[x], 0xFF,
                "cross-cell concatenation row 12 col \(x) must be opaque "
                    + "— a gap here is the dashed-rule defect")
        }
    }

    // MARK: - Block elements

    func testRasterizeFullBlock() throws {
        let bitmap = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x2588)!,  // █
                widthPx: 16, heightPx: 24))
        XCTAssertEqual(bitmap.count, 16 * 24)
        for byte in bitmap {
            XCTAssertEqual(byte, 0xFF, "U+2588 must be 100% opaque")
        }
    }

    func testRasterizeUpperHalfBlock() throws {
        let bitmap = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x2580)!,  // ▀
                widthPx: 16, heightPx: 24))

        for y in 0..<12 {
            for x in 0..<16 {
                XCTAssertEqual(
                    bitmap[y * 16 + x], 0xFF,
                    "U+2580 upper half row \(y) col \(x)")
            }
        }
        for y in 12..<24 {
            for x in 0..<16 {
                XCTAssertEqual(
                    bitmap[y * 16 + x], 0,
                    "U+2580 row \(y) col \(x) must be blank")
            }
        }
    }

    func testRasterizeLowerHalfBlock() throws {
        let bitmap = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x2584)!,  // ▄
                widthPx: 16, heightPx: 24))

        for y in 0..<12 {
            for x in 0..<16 {
                XCTAssertEqual(
                    bitmap[y * 16 + x], 0,
                    "U+2584 row \(y) col \(x) must be blank")
            }
        }
        for y in 12..<24 {
            for x in 0..<16 {
                XCTAssertEqual(
                    bitmap[y * 16 + x], 0xFF,
                    "U+2584 lower half row \(y) col \(x)")
            }
        }
    }

    // MARK: - Shading

    func testShadingMedium() throws {
        let bitmap = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x2592)!,  // ▒
                widthPx: 16, heightPx: 24))
        XCTAssertEqual(bitmap.count, 16 * 24)
        // Medium shade renders as uniform 0x80 coverage.
        for byte in bitmap {
            XCTAssertEqual(
                byte, 0x80,
                "U+2592 medium shade expected 0x80 uniform coverage")
        }
    }

    func testShadingLightAndDarkOrdered() throws {
        // The three shading densities must be strictly increasing in
        // coverage so the visual ordering ░ < ▒ < ▓ holds.
        let light = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x2591)!, widthPx: 8, heightPx: 8))
        let medium = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x2592)!, widthPx: 8, heightPx: 8))
        let dark = try XCTUnwrap(
            BoxDrawing.rasterize(
                scalar: Unicode.Scalar(0x2593)!, widthPx: 8, heightPx: 8))
        XCTAssertLessThan(light[0], medium[0])
        XCTAssertLessThan(medium[0], dark[0])
        XCTAssertGreaterThan(light[0], 0)
        XCTAssertLessThan(dark[0], 0xFF)
    }

    // MARK: - Coverage smoke test

    func testFullCodepointRangeRastersWithoutCrash() {
        // Drive the full handled range. Every codepoint must produce
        // a non-nil bitmap of the correct size (no panic, no nil from
        // a missing case branch). Pixel content per codepoint is not
        // re-asserted here — the targeted geometry tests above pin
        // representative shapes and the visual verification step
        // covers the rest. This guard catches "added a new switch
        // case but forgot to cover the existing range" regressions.
        for value in 0x2500...0x257F {
            let scalar = Unicode.Scalar(value)!
            let bitmap = BoxDrawing.rasterize(
                scalar: scalar, widthPx: 16, heightPx: 24)
            XCTAssertNotNil(bitmap, "U+\(String(value, radix: 16)) returned nil")
            XCTAssertEqual(bitmap?.count, 16 * 24)
        }
        for value in 0x2580...0x259F {
            let scalar = Unicode.Scalar(value)!
            let bitmap = BoxDrawing.rasterize(
                scalar: scalar, widthPx: 16, heightPx: 24)
            XCTAssertNotNil(bitmap, "U+\(String(value, radix: 16)) returned nil")
            XCTAssertEqual(bitmap?.count, 16 * 24)
        }
    }
}
