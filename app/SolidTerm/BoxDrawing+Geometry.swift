// The stroke, fill and trace primitives every `BoxDrawing` range
// function paints through, split out of the one big
// `BoxDrawing.rasterize` switch together with the two direction enums
// their signatures name.
//
// These were file-scope `private` while the rasterizer was one file.
// Twelve declarations widen to internal — still module-private: the ten
// helpers that now have a caller in a sibling file, plus `ArcQuadrant`
// and `DiagonalDirection`, which two of those signatures name and so
// cannot stay less visible than the functions taking them.
// `plotArcPixel` stays private: `arcCorner`, in this file, is its only
// caller.

import Foundation

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
func hLine(
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
func vLine(
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
func block(
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
func shade(
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
func dashedH(
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
func dashedV(
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
func doubleH(
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
func doubleV(
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

enum ArcQuadrant {
    case downRight, downLeft, upLeft, upRight
}

/// Trace a 90° arc joining the cell midline to one of the cell
/// edges, using a Bresenham-style midpoint circle algorithm. The
/// radius is `min(cx, cy)` so the arc clears the cell's centre and
/// touches the midline at the quadrant transitions; stems extending
/// from the arc to the cell edge are painted by the caller.
func arcCorner(
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

enum DiagonalDirection {
    case upRight  // ╱ — bottom-left to top-right
    case downRight  // ╲ — top-left to bottom-right
}

/// Paint a single diagonal stroke at `thickness` device pixels using
/// a step-by-step DDA. We don't anti-alias — the U+2571..U+2573
/// codepoints are infrequent in TUI traffic and the aliased look
/// matches what most fonts produce for them.
func diagonal(
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
