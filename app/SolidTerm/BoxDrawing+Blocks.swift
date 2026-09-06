// The Block Elements block (U+2580-U+259F: half and fractional blocks,
// the three shades, the quadrants) plus the curved and diagonal box-
// drawing arms (U+256D-U+2573), split out of the one big
// `BoxDrawing.rasterize` switch. The arcs and diagonals share this file
// because they are the two ranges that paint through the traced
// helpers rather than through the straight-stroke ones.
//
// Arms are verbatim from the pre-split switch. Geometry helpers live in
// BoxDrawing+Geometry.swift; the dispatcher is in BoxDrawing.swift.

import Foundation

extension BoxDrawing {
    /// Paint U+256D-U+2573 into `bitmap` — the four arc corners and the
    /// three diagonals. Called by `BoxDrawing.rasterize`.
    static func rasterizeArcsAndDiagonals(
        _ bitmap: inout [UInt8],
        scalar: Unicode.Scalar,
        widthPx: Int, heightPx: Int,
        light: Int, heavy: Int,
        cx: Int, cy: Int
    ) {
        switch scalar.value {
        // ─── U+256D..U+2570: arc corners ─────────────────────────────
        // Approximated via a quarter-circle traced by stepping through
        // the relevant 90° arc centered on the joint cell. We don't
        // anti-alias the arc — at the typical 16×24 cell metric the
        // single-pixel stroke reads cleanly, and AA would require a
        // distance-field approach inconsistent with the rest of the
        // procedural path. Stems extending from the arc to the cell
        // edges are straight strokes at the joint axis.
        case 0x256D:  // ╭ light arc down + right
            arcCorner(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                cx: cx, cy: cy, quadrant: .downRight,
                thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx + min(cx, cy), x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy + min(cx, cy), y1: heightPx, thickness: light)
        case 0x256E:  // ╮ light arc down + left
            arcCorner(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                cx: cx, cy: cy, quadrant: .downLeft,
                thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx - min(cx, cy) + light, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy + min(cx, cy), y1: heightPx, thickness: light)
        case 0x256F:  // ╯ light arc up + left
            arcCorner(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                cx: cx, cy: cy, quadrant: .upLeft,
                thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx - min(cx, cy) + light, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy - min(cx, cy) + light, thickness: light)
        case 0x2570:  // ╰ light arc up + right
            arcCorner(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                cx: cx, cy: cy, quadrant: .upRight,
                thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx + min(cx, cy), x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy - min(cx, cy) + light, thickness: light)

        // ─── U+2571..U+2573: diagonals ───────────────────────────────
        case 0x2571:  // ╱ diagonal up-right
            diagonal(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                direction: .upRight, thickness: light)
        case 0x2572:  // ╲ diagonal down-right
            diagonal(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                direction: .downRight, thickness: light)
        case 0x2573:  // ╳ both diagonals
            diagonal(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                direction: .upRight, thickness: light)
            diagonal(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                direction: .downRight, thickness: light)

        default:
            // A codepoint inside this range that the arms above don't
            // name: leave the bitmap blank, as the pre-split switch did.
            // See `BoxDrawing.rasterize` for why blank beats fatal.
            break
        }
    }

    /// Paint U+2580-U+259F into `bitmap` — the Block Elements range.
    /// Called by `BoxDrawing.rasterize`.
    static func rasterizeBlocks(
        _ bitmap: inout [UInt8],
        scalar: Unicode.Scalar,
        widthPx: Int, heightPx: Int,
        light: Int, heavy: Int,
        cx: Int, cy: Int
    ) {
        switch scalar.value {
        // ─── U+2580..U+2587: half / quarter-vertical blocks ──────────
        case 0x2580:  // ▀ upper half block
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: widthPx, y1: heightPx / 2)
        case 0x2581:  // ▁ lower one eighth
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: heightPx * 7 / 8, x1: widthPx, y1: heightPx)
        case 0x2582:  // ▂ lower one quarter
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: heightPx * 6 / 8, x1: widthPx, y1: heightPx)
        case 0x2583:  // ▃ lower three eighths
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: heightPx * 5 / 8, x1: widthPx, y1: heightPx)
        case 0x2584:  // ▄ lower half block
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: heightPx / 2, x1: widthPx, y1: heightPx)
        case 0x2585:  // ▅ lower five eighths
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: heightPx * 3 / 8, x1: widthPx, y1: heightPx)
        case 0x2586:  // ▆ lower three quarters
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: heightPx * 2 / 8, x1: widthPx, y1: heightPx)
        case 0x2587:  // ▇ lower seven eighths
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: heightPx * 1 / 8, x1: widthPx, y1: heightPx)

        // ─── U+2588..U+258F: full + left fractional blocks ───────────
        case 0x2588:  // █ full block
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: widthPx, y1: heightPx)
        case 0x2589:  // ▉ left seven eighths
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: widthPx * 7 / 8, y1: heightPx)
        case 0x258A:  // ▊ left three quarters
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: widthPx * 6 / 8, y1: heightPx)
        case 0x258B:  // ▋ left five eighths
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: widthPx * 5 / 8, y1: heightPx)
        case 0x258C:  // ▌ left half block
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: widthPx / 2, y1: heightPx)
        case 0x258D:  // ▍ left three eighths
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: widthPx * 3 / 8, y1: heightPx)
        case 0x258E:  // ▎ left one quarter
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: widthPx * 2 / 8, y1: heightPx)
        case 0x258F:  // ▏ left one eighth
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: max(1, widthPx * 1 / 8), y1: heightPx)

        // ─── U+2590..U+2593: right half + shading ────────────────────
        case 0x2590:  // ▐ right half block
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: widthPx / 2, y0: 0, x1: widthPx, y1: heightPx)
        case 0x2591:  // ░ light shade (~25 %)
            shade(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                value: 0x40)
        case 0x2592:  // ▒ medium shade (~50 %)
            shade(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                value: 0x80)
        case 0x2593:  // ▓ dark shade (~75 %)
            shade(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                value: 0xC0)

        // ─── U+2594..U+2595: top + right one-eighth ──────────────────
        case 0x2594:  // ▔ upper one eighth
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: widthPx, y1: max(1, heightPx / 8))
        case 0x2595:  // ▕ right one eighth
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: widthPx - max(1, widthPx / 8), y0: 0,
                x1: widthPx, y1: heightPx)

        // ─── U+2596..U+259F: quadrant blocks ─────────────────────────
        case 0x2596:  // ▖ quadrant lower left
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: heightPx / 2, x1: widthPx / 2, y1: heightPx)
        case 0x2597:  // ▗ quadrant lower right
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: widthPx / 2, y0: heightPx / 2,
                x1: widthPx, y1: heightPx)
        case 0x2598:  // ▘ quadrant upper left
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: widthPx / 2, y1: heightPx / 2)
        case 0x2599:  // ▙ quadrant UL+LL+LR
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: widthPx / 2, y1: heightPx / 2)
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: heightPx / 2, x1: widthPx, y1: heightPx)
        case 0x259A:  // ▚ quadrant UL+LR
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: widthPx / 2, y1: heightPx / 2)
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: widthPx / 2, y0: heightPx / 2,
                x1: widthPx, y1: heightPx)
        case 0x259B:  // ▛ quadrant UL+UR+LL
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: widthPx, y1: heightPx / 2)
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: heightPx / 2, x1: widthPx / 2, y1: heightPx)
        case 0x259C:  // ▜ quadrant UL+UR+LR
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: 0, x1: widthPx, y1: heightPx / 2)
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: widthPx / 2, y0: heightPx / 2,
                x1: widthPx, y1: heightPx)
        case 0x259D:  // ▝ quadrant upper right
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: widthPx / 2, y0: 0,
                x1: widthPx, y1: heightPx / 2)
        case 0x259E:  // ▞ quadrant UR+LL
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: widthPx / 2, y0: 0,
                x1: widthPx, y1: heightPx / 2)
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: heightPx / 2, x1: widthPx / 2, y1: heightPx)
        case 0x259F:  // ▟ quadrant UR+LL+LR
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: widthPx / 2, y0: 0,
                x1: widthPx, y1: heightPx / 2)
            block(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x0: 0, y0: heightPx / 2, x1: widthPx, y1: heightPx)

        default:
            // A codepoint inside this range that the arms above don't
            // name: leave the bitmap blank, as the pre-split switch did.
            // See `BoxDrawing.rasterize` for why blank beats fatal.
            break
        }
    }
}
