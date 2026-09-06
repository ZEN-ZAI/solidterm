// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Procedural box-drawing + block-element rasterizer for the Unicode
// ranges U+2500-U+257F (box drawing) and U+2580-U+259F (block
// elements). Intercepts these scalars BEFORE the GlyphAtlas font
// fallback path so horizontal/vertical rules join pixel-perfectly
// across cell boundaries regardless of the user's font choice.
//
// Why procedural? Most monospace fonts render U+2500 ─ as a glyph
// whose horizontal extent stops short of the cell's advance width,
// producing a visibly dashed line when adjacent cells abut.
// Standard practice in modern terminals is to bypass the font for
// these characters and paint the geometry at the exact cell metric:
//
//   - Ghostty:   src/font/sprite/Box.zig
//   - Kitty:     kitty/box_drawing.py
//   - WezTerm:   wezterm-font/src/sbd.rs
//   - Alacritty: alacritty/src/renderer/text/builtin_font.rs (≥0.13)
//
// The shapes are reproduced from the Unicode 15.1 code chart for
// "Box Drawing" and "Block Elements" — see
// https://www.unicode.org/charts/PDF/U2500.pdf and
// https://www.unicode.org/charts/PDF/U2580.pdf.
//
// Output bitmap layout: row-major top-down, one byte per pixel,
// length = widthPx * heightPx. 0 = fully transparent, 255 = fully
// opaque. Matches the byte layout that `GlyphAtlas.rasterize()`
// produces from CoreText so the procedural and font paths share the
// same `place()` blit upload without translation.
//
// The per-codepoint arms are split across sibling files, one function
// per Unicode range, with `rasterize` below reduced to the dispatcher
// that picks between them: U+2500-U+254F and U+2574-U+257F in
// BoxDrawing+Lines.swift, U+2550-U+256C in BoxDrawing+Double.swift,
// U+256D-U+2573 and U+2580-U+259F in BoxDrawing+Blocks.swift, and the
// geometry primitives they all paint through in
// BoxDrawing+Geometry.swift.

import Foundation

/// Procedural rasterizer for U+2500-U+259F. Caller is `GlyphAtlas`.
enum BoxDrawing {
    /// Whether `scalar` is one of the procedurally-rendered codepoints.
    /// Scalars in the handled ranges MUST NOT fall through to font
    /// resolution — fonts paint these glyphs at varying extents that
    /// won't tile cleanly across cell boundaries.
    static func handles(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2500...0x257F: return true  // Box Drawing
        case 0x2580...0x259F: return true  // Block Elements
        default: return false
        }
    }

    /// Render `scalar` to a `widthPx × heightPx` grayscale coverage
    /// bitmap. Returns `nil` if `scalar` is outside the handled ranges
    /// (caller should guard via `handles(_:)` first; the nil return is
    /// a defensive contract pin, not a happy-path branch).
    ///
    /// The bitmap is row-major top-down: `bitmap[y * widthPx + x]`
    /// gives pixel (x, y) where (0, 0) is the top-left.
    static func rasterize(
        scalar: Unicode.Scalar,
        widthPx: Int,
        heightPx: Int
    ) -> [UInt8]? {
        guard handles(scalar) else { return nil }
        guard widthPx > 0, heightPx > 0 else { return nil }

        var bitmap = [UInt8](repeating: 0, count: widthPx * heightPx)

        // Stroke-width metrics. `light` is the canonical thin stroke;
        // `heavy` is roughly 2× thick; `double` paints two parallel
        // light strokes with a 1-stroke gap. Formula picks 1 device
        // pixel for typical 1× cells (width 16, height 24) and scales
        // proportionally as cell height grows past 2× retina sizes.
        let light = max(1, heightPx / 24)
        let heavy = max(2, light * 2)

        // Geometric anchors. `cy` and `cx` are the mid-row / mid-column
        // pixel indices used as the joining axis for corners, tees,
        // and crosses. Computed as floor(size / 2): for size=24 the
        // mid is row 12 (so rows 11,12 are equidistant from the top
        // and bottom edges within a stroke of even thickness, and
        // a thickness-1 stroke lands exactly on row 12 — matching the
        // test's "y=12 opaque" pin).
        let cy = heightPx / 2
        let cx = widthPx / 2

        switch scalar.value {

        case 0x2500...0x254F:
            rasterizeLines(
                &bitmap, scalar: scalar,
                widthPx: widthPx, heightPx: heightPx,
                light: light, heavy: heavy, cx: cx, cy: cy)

        case 0x2550...0x256C:
            rasterizeDouble(
                &bitmap, scalar: scalar,
                widthPx: widthPx, heightPx: heightPx,
                light: light, heavy: heavy, cx: cx, cy: cy)

        case 0x256D...0x2573:
            rasterizeArcsAndDiagonals(
                &bitmap, scalar: scalar,
                widthPx: widthPx, heightPx: heightPx,
                light: light, heavy: heavy, cx: cx, cy: cy)

        case 0x2574...0x257F:
            rasterizeHalfStrokes(
                &bitmap, scalar: scalar,
                widthPx: widthPx, heightPx: heightPx,
                light: light, heavy: heavy, cx: cx, cy: cy)

        case 0x2580...0x259F:
            rasterizeBlocks(
                &bitmap, scalar: scalar,
                widthPx: widthPx, heightPx: heightPx,
                light: light, heavy: heavy, cx: cx, cy: cy)

        default:
            // Unreachable: the five ranges above tile exactly what
            // `handles(_:)` accepts. If a range ever goes missing here,
            // leave the bitmap blank — the visual result is "tofu-like"
            // but never crashes the renderer. Defensive over fatal:
            // terminal traffic in the wild may include reserved
            // codepoints.
            break
        }

        return bitmap
    }
}
