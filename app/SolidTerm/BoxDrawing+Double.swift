// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// The double-stroke half of the Box Drawing block, split out of the one
// big `BoxDrawing.rasterize` switch: U+2550-U+256C — the double
// horizontal and vertical, and the corner / tee / cross families that
// mix a single stroke on one axis with a double stroke on the other.
//
// Arms are verbatim from the pre-split switch. Geometry helpers live in
// BoxDrawing+Geometry.swift; the dispatcher is in BoxDrawing.swift.

import Foundation

extension BoxDrawing {
    /// Paint U+2550-U+256C into `bitmap`. Called by
    /// `BoxDrawing.rasterize` for that range only.
    static func rasterizeDouble(
        _ bitmap: inout [UInt8],
        scalar: Unicode.Scalar,
        widthPx: Int, heightPx: Int,
        light: Int, heavy: Int,
        cx: Int, cy: Int
    ) {
        switch scalar.value {
        // ─── U+2550..U+2551: double horizontal/vertical ──────────────
        case 0x2550:  // ═ double horizontal
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, light: light)
        case 0x2551:  // ║ double vertical
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, light: light)

        // ─── U+2552..U+2554: down-and-right (single+double mixes) ────
        // For codepoints mixing single+double, the "double" axis paints
        // two parallel rails; the "single" axis paints one. Joining is
        // approximate at the corner — we paint each axis from the cell
        // edge to the centre, accepting a small overlap at the joint.
        case 0x2552:  // ╒ down single + right double
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, light: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x2553:  // ╓ down double + right single
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, light: light)
        case 0x2554:  // ╔ down + right double
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, light: light)
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, light: light)

        // ─── U+2555..U+2557: down-and-left (single+double mixes) ─────
        case 0x2555:  // ╕ down single + left double
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, light: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x2556:  // ╖ down double + left single
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, thickness: light)
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, light: light)
        case 0x2557:  // ╗ down + left double
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, light: light)
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, light: light)

        // ─── U+2558..U+255A: up-and-right (single+double mixes) ──────
        case 0x2558:  // ╘ up single + right double
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, light: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, thickness: light)
        case 0x2559:  // ╙ up double + right single
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, light: light)
        case 0x255A:  // ╚ up + right double
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, light: light)
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, light: light)

        // ─── U+255B..U+255D: up-and-left (single+double mixes) ───────
        case 0x255B:  // ╛ up single + left double
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, light: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, thickness: light)
        case 0x255C:  // ╜ up double + left single
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, thickness: light)
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, light: light)
        case 0x255D:  // ╝ up + left double
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, light: light)
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, light: light)

        // ─── U+255E..U+2560: vertical-and-right tees (mixes) ─────────
        case 0x255E:  // ╞ vertical single + right double
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: light)
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, light: light)
        case 0x255F:  // ╟ vertical double + right single
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, light: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
        case 0x2560:  // ╠ vertical + right double
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, light: light)
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, light: light)

        // ─── U+2561..U+2563: vertical-and-left tees (mixes) ──────────
        case 0x2561:  // ╡ vertical single + left double
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: light)
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, light: light)
        case 0x2562:  // ╢ vertical double + left single
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, light: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, thickness: light)
        case 0x2563:  // ╣ vertical + left double
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, light: light)
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, light: light)

        // ─── U+2564..U+2566: horizontal-and-down tees (mixes) ────────
        case 0x2564:  // ╤ horizontal double + down single
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, light: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x2565:  // ╥ horizontal single + down double
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: light)
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, light: light)
        case 0x2566:  // ╦ horizontal + down double
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, light: light)
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, light: light)

        // ─── U+2567..U+2569: horizontal-and-up tees (mixes) ──────────
        case 0x2567:  // ╧ horizontal double + up single
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, light: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, thickness: light)
        case 0x2568:  // ╨ horizontal single + up double
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: light)
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, light: light)
        case 0x2569:  // ╩ horizontal + up double
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, light: light)
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, light: light)

        // ─── U+256A..U+256C: crosses (mixes) ─────────────────────────
        case 0x256A:  // ╪ horizontal double + vertical single
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, light: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: light)
        case 0x256B:  // ╫ horizontal single + vertical double
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: light)
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, light: light)
        case 0x256C:  // ╬ double cross
            doubleH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, light: light)
            doubleV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, light: light)

        default:
            // A codepoint inside this range that the arms above don't
            // name: leave the bitmap blank, as the pre-split switch did.
            // See `BoxDrawing.rasterize` for why blank beats fatal.
            break
        }
    }
}
