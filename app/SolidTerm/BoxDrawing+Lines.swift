// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// The single-stroke half of the Box Drawing block, split out of the
// one big `BoxDrawing.rasterize` switch: U+2500-U+254F (light/heavy
// and dashed horizontals and verticals, the four corner families, the
// four tee families, the sixteen crosses, the double-dash strokes) and
// U+2574-U+257F (the half-strokes and the mixed light/heavy halves,
// which are line geometry too and so live here rather than with the
// blocks they sit next to in the code chart).
//
// Arms are verbatim from the pre-split switch. Geometry helpers live in
// BoxDrawing+Geometry.swift; the dispatcher is in BoxDrawing.swift.

import Foundation

extension BoxDrawing {
    /// Paint U+2500-U+254F into `bitmap`. Called by
    /// `BoxDrawing.rasterize` for that range only.
    static func rasterizeLines(
        _ bitmap: inout [UInt8],
        scalar: Unicode.Scalar,
        widthPx: Int, heightPx: Int,
        light: Int, heavy: Int,
        cx: Int, cy: Int
    ) {
        switch scalar.value {
        // ─── U+2500..U+2503: light/heavy horizontal/vertical ─────────
        case 0x2500:  // ─ light horizontal
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: light)
        case 0x2501:  // ━ heavy horizontal
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: heavy)
        case 0x2502:  // │ light vertical
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: light)
        case 0x2503:  // ┃ heavy vertical
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: heavy)

        // ─── U+2504..U+250B: dashed horizontal/vertical ──────────────
        // Triple-dash (504/505), quadruple-dash (508/509), quadruple
        // continued (50A/50B). Kitty/Alacritty render these by
        // dividing the cell extent into N segments with N gaps.
        case 0x2504:  // ┄ light triple dash horizontal
            dashedH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, segments: 3, thickness: light)
        case 0x2505:  // ┅ heavy triple dash horizontal
            dashedH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, segments: 3, thickness: heavy)
        case 0x2506:  // ┆ light triple dash vertical
            dashedV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, segments: 3, thickness: light)
        case 0x2507:  // ┇ heavy triple dash vertical
            dashedV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, segments: 3, thickness: heavy)
        case 0x2508:  // ┈ light quadruple dash horizontal
            dashedH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, segments: 4, thickness: light)
        case 0x2509:  // ┉ heavy quadruple dash horizontal
            dashedH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, segments: 4, thickness: heavy)
        case 0x250A:  // ┊ light quadruple dash vertical
            dashedV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, segments: 4, thickness: light)
        case 0x250B:  // ┋ heavy quadruple dash vertical
            dashedV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, segments: 4, thickness: heavy)

        // ─── U+250C..U+250F: light/heavy down-and-right corners ──────
        case 0x250C:  // ┌ light down + right
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x250D:  // ┍ down light + right heavy
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x250E:  // ┎ down heavy + right light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)
        case 0x250F:  // ┏ heavy down + right
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)

        // ─── U+2510..U+2513: light/heavy down-and-left corners ───────
        case 0x2510:  // ┐ light down + left
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x2511:  // ┑ down light + left heavy
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + heavy, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x2512:  // ┒ down heavy + left light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)
        case 0x2513:  // ┓ heavy down + left
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + heavy, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)

        // ─── U+2514..U+2517: light/heavy up-and-right corners ────────
        case 0x2514:  // └ light up + right
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, thickness: light)
        case 0x2515:  // ┕ up light + right heavy
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + heavy, thickness: light)
        case 0x2516:  // ┖ up heavy + right light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, thickness: heavy)
        case 0x2517:  // ┗ heavy up + right
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + heavy, thickness: heavy)

        // ─── U+2518..U+251B: light/heavy up-and-left corners ─────────
        case 0x2518:  // ┘ light up + left
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, thickness: light)
        case 0x2519:  // ┙ up light + left heavy
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + heavy, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + heavy, thickness: light)
        case 0x251A:  // ┚ up heavy + left light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, thickness: heavy)
        case 0x251B:  // ┛ heavy up + left
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + heavy, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + heavy, thickness: heavy)

        // ─── U+251C..U+2523: vertical-and-right tees ─────────────────
        case 0x251C:  // ├ light vertical + right
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
        case 0x251D:  // ┝ vertical light + right heavy
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
        case 0x251E:  // ┞ up heavy + down light + right light
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
        case 0x251F:  // ┟ up light + down heavy + right light
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
        case 0x2520:  // ┠ vertical heavy + right light
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
        case 0x2521:  // ┡ down light + up heavy + right heavy
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
        case 0x2522:  // ┢ up light + down heavy + right heavy
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
        case 0x2523:  // ┣ heavy vertical + right
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)

        // ─── U+2524..U+252B: vertical-and-left tees ──────────────────
        case 0x2524:  // ┤ light vertical + left
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, thickness: light)
        case 0x2525:  // ┥ vertical light + left heavy
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + heavy, thickness: heavy)
        case 0x2526:  // ┦ up heavy + down light + left light
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, thickness: light)
        case 0x2527:  // ┧ up light + down heavy + left light
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, thickness: light)
        case 0x2528:  // ┨ vertical heavy + left light
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, thickness: light)
        case 0x2529:  // ┩ up heavy + down light + left heavy
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + heavy, thickness: heavy)
        case 0x252A:  // ┪ up light + down heavy + left heavy
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + heavy, thickness: heavy)
        case 0x252B:  // ┫ heavy vertical + left
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + heavy, thickness: heavy)

        // ─── U+252C..U+2533: horizontal-and-down tees ────────────────
        case 0x252C:  // ┬ light horizontal + down
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x252D:  // ┭ left heavy + right light + down light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x252E:  // ┮ left light + right heavy + down light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x252F:  // ┯ horizontal heavy + down light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x2530:  // ┰ horizontal light + down heavy
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)
        case 0x2531:  // ┱ left heavy + right light + down heavy
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)
        case 0x2532:  // ┲ left light + right heavy + down heavy
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)
        case 0x2533:  // ┳ heavy horizontal + down
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)

        // ─── U+2534..U+253B: horizontal-and-up tees ──────────────────
        case 0x2534:  // ┴ light horizontal + up
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, thickness: light)
        case 0x2535:  // ┵ left heavy + right light + up light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, thickness: light)
        case 0x2536:  // ┶ left light + right heavy + up light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, thickness: light)
        case 0x2537:  // ┷ horizontal heavy + up light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + heavy, thickness: light)
        case 0x2538:  // ┸ horizontal light + up heavy
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, thickness: heavy)
        case 0x2539:  // ┹ left heavy + right light + up heavy
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, thickness: heavy)
        case 0x253A:  // ┺ left light + right heavy + up heavy
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, thickness: heavy)
        case 0x253B:  // ┻ heavy horizontal + up
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + heavy, thickness: heavy)

        // ─── U+253C..U+254B: crosses (16 light/heavy combos) ─────────
        case 0x253C:  // ┼ light vertical + horizontal
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: light)
        case 0x253D:  // ┽ left heavy + right light + vertical light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: light)
        case 0x253E:  // ┾ left light + right heavy + vertical light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: light)
        case 0x253F:  // ┿ horizontal heavy + vertical light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: light)
        case 0x2540:  // ╀ up heavy + down light + horizontal light
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: light)
        case 0x2541:  // ╁ up light + down heavy + horizontal light
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: light)
        case 0x2542:  // ╂ vertical heavy + horizontal light
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: light)
        case 0x2543:  // ╃ left heavy + up heavy + right light + down light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x2544:  // ╄ right heavy + up heavy + left light + down light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x2545:  // ╅ left heavy + down heavy + right light + up light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)
        case 0x2546:  // ╆ right heavy + down heavy + left light + up light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)
        case 0x2547:  // ╇ horizontal heavy + up heavy + down light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x2548:  // ╈ horizontal heavy + down heavy + up light
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)
        case 0x2549:  // ╉ vertical heavy + left heavy + right light
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
        case 0x254A:  // ╊ vertical heavy + right heavy + left light
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
        case 0x254B:  // ╋ heavy cross
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: widthPx, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: heightPx, thickness: heavy)

        // ─── U+254C..U+254F: light/heavy double-dash ─────────────────
        case 0x254C:  // ╌ light double dash horizontal
            dashedH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, segments: 2, thickness: light)
        case 0x254D:  // ╍ heavy double dash horizontal
            dashedH(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, segments: 2, thickness: heavy)
        case 0x254E:  // ╎ light double dash vertical
            dashedV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, segments: 2, thickness: light)
        case 0x254F:  // ╏ heavy double dash vertical
            dashedV(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, segments: 2, thickness: heavy)

        default:
            // A codepoint inside this range that the arms above don't
            // name: leave the bitmap blank, as the pre-split switch did.
            // See `BoxDrawing.rasterize` for why blank beats fatal.
            break
        }
    }

    /// Paint U+2574-U+257F into `bitmap` — the half-strokes and the
    /// mixed light/heavy halves. Called by `BoxDrawing.rasterize`.
    static func rasterizeHalfStrokes(
        _ bitmap: inout [UInt8],
        scalar: Unicode.Scalar,
        widthPx: Int, heightPx: Int,
        light: Int, heavy: Int,
        cx: Int, cy: Int
    ) {
        switch scalar.value {
        // ─── U+2574..U+257B: half-strokes (left/up/right/down only) ──
        case 0x2574:  // ╴ light left half
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + light, thickness: light)
        case 0x2575:  // ╵ light up half
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + light, thickness: light)
        case 0x2576:  // ╶ light right half
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
        case 0x2577:  // ╷ light down half
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)
        case 0x2578:  // ╸ heavy left half
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx + heavy, thickness: heavy)
        case 0x2579:  // ╹ heavy up half
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy + heavy, thickness: heavy)
        case 0x257A:  // ╺ heavy right half
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
        case 0x257B:  // ╻ heavy down half
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)

        // ─── U+257C..U+257F: mixed light/heavy halves ────────────────
        case 0x257C:  // ╼ light left + heavy right
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: light)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: heavy)
        case 0x257D:  // ╽ light up + heavy down
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: light)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: heavy)
        case 0x257E:  // ╾ heavy left + light right
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: 0, x1: cx, thickness: heavy)
            hLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                y: cy, x0: cx, x1: widthPx, thickness: light)
        case 0x257F:  // ╿ heavy up + light down
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: 0, y1: cy, thickness: heavy)
            vLine(
                &bitmap, widthPx: widthPx, heightPx: heightPx,
                x: cx, y0: cy, y1: heightPx, thickness: light)

        default:
            // A codepoint inside this range that the arms above don't
            // name: leave the bitmap blank, as the pre-split switch did.
            // See `BoxDrawing.rasterize` for why blank beats fatal.
            break
        }
    }
}
