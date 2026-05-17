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
            // Unreachable: `handles(_:)` filters everything outside the
            // explicit cases above. If a new codepoint slips into the
            // range without a case here, leave the bitmap blank — the
            // visual result is "tofu-like" but never crashes the
            // renderer. Defensive over fatal: terminal traffic in the
            // wild may include reserved codepoints.
            break
        }

        return bitmap
    }
}

// MARK: - Geometry helpers

/// Paint a horizontal line of `thickness` pixels centered on `y`,
/// spanning `[x0, x1)` columns. The thickness is distributed
/// symmetrically: even thickness puts the extra row above the
/// midline (y - thickness/2 ... y + ceil(thickness/2)).
///
/// The half-open `[x0, x1)` range is load-bearing: passing
/// `x1 = widthPx` paints the rightmost pixel column, so adjacent
/// cells abutting at the right edge produce an unbroken line. An
/// off-by-one truncation here is exactly the dashed-rule defect
/// procedural rendering exists to avoid.
private func hLine(
    _ bitmap: inout [UInt8],
    widthPx: Int, heightPx: Int,
    y: Int, x0: Int, x1: Int, thickness: Int
) {
    guard thickness > 0 else { return }
    let yStart = max(0, y - thickness / 2)
    let yEnd = min(heightPx, yStart + thickness)
    let xStart = max(0, x0)
    let xEnd = min(widthPx, x1)
    for yy in yStart..<yEnd {
        let row = yy * widthPx
        for xx in xStart..<xEnd {
            bitmap[row + xx] = 0xFF
        }
    }
}

/// Paint a vertical line of `thickness` pixels centered on `x`,
/// spanning `[y0, y1)` rows.
private func vLine(
    _ bitmap: inout [UInt8],
    widthPx: Int, heightPx: Int,
    x: Int, y0: Int, y1: Int, thickness: Int
) {
    guard thickness > 0 else { return }
    let xStart = max(0, x - thickness / 2)
    let xEnd = min(widthPx, xStart + thickness)
    let yStart = max(0, y0)
    let yEnd = min(heightPx, y1)
    for yy in yStart..<yEnd {
        let row = yy * widthPx
        for xx in xStart..<xEnd {
            bitmap[row + xx] = 0xFF
        }
    }
}

/// Fill a solid rectangle `[x0, x1) × [y0, y1)` with full coverage.
/// Used by every block-element codepoint and by the corner-stem
/// painters when a thicker rectangular fill is wanted.
private func block(
    _ bitmap: inout [UInt8],
    widthPx: Int, heightPx: Int,
    x0: Int, y0: Int, x1: Int, y1: Int
) {
    let xStart = max(0, x0)
    let xEnd = min(widthPx, x1)
    let yStart = max(0, y0)
    let yEnd = min(heightPx, y1)
    for yy in yStart..<yEnd {
        let row = yy * widthPx
        for xx in xStart..<xEnd {
            bitmap[row + xx] = 0xFF
        }
    }
}

/// Paint a uniform shading at coverage `value`. Trade-off vs a
/// stipple pattern: uniform fill samples cleanly under the atlas's
/// linear filter (no Moiré at sub-cell zoom) and produces the same
/// perceived density as a properly-tuned stipple. Stipple is the
/// historically-accurate rendering, but the shaders that consume
/// the atlas already premultiply by foreground alpha — uniform
/// coverage at the canonical density value is visually identical
/// once tinted.
private func shade(
    _ bitmap: inout [UInt8],
    widthPx: Int, heightPx: Int,
    value: UInt8
) {
    for i in 0..<(widthPx * heightPx) {
        bitmap[i] = value
    }
}

/// Paint a dashed horizontal line — `segments` dash segments
/// separated by gaps of equal width (gap = ~1/3 segment per Unicode
/// chart). The total dash+gap pattern fills the cell width.
private func dashedH(
    _ bitmap: inout [UInt8],
    widthPx: Int, heightPx: Int,
    y: Int, segments: Int, thickness: Int
) {
    guard segments > 0, widthPx > 0 else { return }
    // Each segment occupies one slot of `2*segments` total slots
    // (dash+gap). The dash itself is the first 60% of the slot,
    // followed by a 40% gap, matching Kitty's proportions.
    let slotW = widthPx / segments
    let dashW = max(1, slotW * 3 / 5)
    for s in 0..<segments {
        let x0 = s * slotW
        let x1 = x0 + dashW
        hLine(
            &bitmap, widthPx: widthPx, heightPx: heightPx,
            y: y, x0: x0, x1: x1, thickness: thickness)
    }
}

/// Paint a dashed vertical line — see `dashedH` for proportions.
private func dashedV(
    _ bitmap: inout [UInt8],
    widthPx: Int, heightPx: Int,
    x: Int, segments: Int, thickness: Int
) {
    guard segments > 0, heightPx > 0 else { return }
    let slotH = heightPx / segments
    let dashH = max(1, slotH * 3 / 5)
    for s in 0..<segments {
        let y0 = s * slotH
        let y1 = y0 + dashH
        vLine(
            &bitmap, widthPx: widthPx, heightPx: heightPx,
            x: x, y0: y0, y1: y1, thickness: thickness)
    }
}

/// Paint a double horizontal line: two parallel light strokes with
/// a 2× gap between (the gap reads as a clear band at typical cell
/// metrics). Strokes flank the midline, distance `light` from it.
private func doubleH(
    _ bitmap: inout [UInt8],
    widthPx: Int, heightPx: Int,
    y: Int, x0: Int, x1: Int, light: Int
) {
    let topY = max(0, y - light - light)
    let botY = min(heightPx - 1, y + light)
    hLine(
        &bitmap, widthPx: widthPx, heightPx: heightPx,
        y: topY, x0: x0, x1: x1, thickness: light)
    hLine(
        &bitmap, widthPx: widthPx, heightPx: heightPx,
        y: botY, x0: x0, x1: x1, thickness: light)
}

/// Paint a double vertical line — see `doubleH` for layout.
private func doubleV(
    _ bitmap: inout [UInt8],
    widthPx: Int, heightPx: Int,
    x: Int, y0: Int, y1: Int, light: Int
) {
    let leftX = max(0, x - light - light)
    let rightX = min(widthPx - 1, x + light)
    vLine(
        &bitmap, widthPx: widthPx, heightPx: heightPx,
        x: leftX, y0: y0, y1: y1, thickness: light)
    vLine(
        &bitmap, widthPx: widthPx, heightPx: heightPx,
        x: rightX, y0: y0, y1: y1, thickness: light)
}

private enum ArcQuadrant {
    case downRight, downLeft, upLeft, upRight
}

/// Trace a 90° arc joining the cell midline to one of the cell
/// edges, using a Bresenham-style midpoint circle algorithm. The
/// radius is `min(cx, cy)` so the arc clears the cell's centre and
/// touches the midline at the quadrant transitions; stems extending
/// from the arc to the cell edge are painted by the caller.
private func arcCorner(
    _ bitmap: inout [UInt8],
    widthPx: Int, heightPx: Int,
    cx: Int, cy: Int, quadrant: ArcQuadrant, thickness: Int
) {
    let r = min(cx, cy)
    guard r > 0 else { return }
    // Centre of the arc circle: positioned so the arc starts on the
    // cell's midline and curves toward the corresponding cell edge.
    let centerX: Int
    let centerY: Int
    switch quadrant {
    case .downRight:
        centerX = cx + r
        centerY = cy + r
    case .downLeft:
        centerX = cx - r
        centerY = cy + r
    case .upLeft:
        centerX = cx - r
        centerY = cy - r
    case .upRight:
        centerX = cx + r
        centerY = cy - r
    }
    // Bresenham's midpoint circle producing pixel coordinates on the
    // full circle; we filter by quadrant relative to the arc centre.
    var x = r
    var y = 0
    var err = 0
    while x >= y {
        plotArcPixel(
            &bitmap, widthPx: widthPx, heightPx: heightPx,
            centerX: centerX, centerY: centerY,
            dx: x, dy: y, quadrant: quadrant, thickness: thickness)
        plotArcPixel(
            &bitmap, widthPx: widthPx, heightPx: heightPx,
            centerX: centerX, centerY: centerY,
            dx: y, dy: x, quadrant: quadrant, thickness: thickness)
        y += 1
        err += 1 + 2 * y
        if 2 * (err - x) + 1 > 0 {
            x -= 1
            err += 1 - 2 * x
        }
    }
}

private func plotArcPixel(
    _ bitmap: inout [UInt8],
    widthPx: Int, heightPx: Int,
    centerX: Int, centerY: Int,
    dx: Int, dy: Int, quadrant: ArcQuadrant, thickness: Int
) {
    // Each call to Bresenham produces a candidate (dx, dy) offset from
    // the arc circle centre; we accept only the offset whose sign
    // matches the quadrant facing the cell interior. E.g., a downRight
    // arc has its centre at (cx+r, cy+r) and the visible quarter is
    // the upper-left of that circle (-dx, -dy).
    let signX: Int
    let signY: Int
    switch quadrant {
    case .downRight:
        signX = -1
        signY = -1
    case .downLeft:
        signX = 1
        signY = -1
    case .upLeft:
        signX = 1
        signY = 1
    case .upRight:
        signX = -1
        signY = 1
    }
    let px = centerX + signX * dx
    let py = centerY + signY * dy
    // Stamp a `thickness × thickness` square at (px, py) so the arc
    // matches the linear-stroke thickness used elsewhere.
    let half = thickness / 2
    for ty in (py - half)..<(py - half + thickness) {
        guard ty >= 0, ty < heightPx else { continue }
        let row = ty * widthPx
        for tx in (px - half)..<(px - half + thickness) {
            guard tx >= 0, tx < widthPx else { continue }
            bitmap[row + tx] = 0xFF
        }
    }
}

private enum DiagonalDirection {
    case upRight  // ╱ — bottom-left to top-right
    case downRight  // ╲ — top-left to bottom-right
}

/// Paint a single diagonal stroke at `thickness` device pixels using
/// a step-by-step DDA. We don't anti-alias — the U+2571..U+2573
/// codepoints are infrequent in TUI traffic and the aliased look
/// matches what most fonts produce for them.
private func diagonal(
    _ bitmap: inout [UInt8],
    widthPx: Int, heightPx: Int,
    direction: DiagonalDirection, thickness: Int
) {
    let steps = max(widthPx, heightPx)
    guard steps > 0 else { return }
    for i in 0..<steps {
        let xf = Double(i) * Double(widthPx) / Double(steps)
        let yf: Double
        switch direction {
        case .upRight:
            yf = Double(heightPx - 1) - Double(i) * Double(heightPx) / Double(steps)
        case .downRight:
            yf = Double(i) * Double(heightPx) / Double(steps)
        }
        let px = Int(xf)
        let py = Int(yf)
        let half = thickness / 2
        for ty in (py - half)..<(py - half + thickness) {
            guard ty >= 0, ty < heightPx else { continue }
            let row = ty * widthPx
            for tx in (px - half)..<(px - half + thickness) {
                guard tx >= 0, tx < widthPx else { continue }
                bitmap[row + tx] = 0xFF
            }
        }
    }
}
