// Glyph resolution and rasterization for `GlyphAtlas`, split out of the
// single-file atlas along its existing MARKs: the scalar → (glyphId,
// font) fallback cascade, the CoreText rasterization into a deviceGray
// `CGContext`, and the pinned blank slot at atlas (0, 0). Stored
// properties live in GlyphAtlas.swift because extensions cannot declare
// them.

import CoreText
import Foundation
import Metal

extension GlyphAtlas {
    // MARK: - Glyph resolution + rasterization

    /// Resolve a scalar to its `(glyphId, font)` pair. Walks the
    /// fallback cascade only when the primary font lacks a glyph.
    /// Astral scalars (> U+FFFF) skip the BMP fast path and go
    /// straight to CoreText's per-string resolver, which handles
    /// surrogate-pair encoding internally.
    ///
    /// DELIBERATE DEVIATION (pre-authorized): the original design
    /// called for a static `kCTFontCascadeListAttribute` chain
    /// (Menlo → PingFang → Hiragino → Thonburi → AppleColorEmoji →
    /// LastResort). M1 task 4.3 overrode that with the per-string
    /// `CTFontCreateForStringWithLanguage` call below.
    /// Per-string resolution is language-aware (Han disambiguation)
    /// and avoids the static-chain failure mode where a font lower
    /// in the chain shadows a better match in a font higher up.
    /// Cascade-list-attribute remains the right
    /// tool when we want a single shaping run to draw a mixed-script
    /// line via `CTLine` (M2+ shape-cache work).
    func resolveGlyph(
        for scalar: Unicode.Scalar
    ) throws -> (CGGlyph, CTFont) {
        // Emoji-presentation-default scalars (⚡ U+26A1, etc.) must render
        // in color even when the monospace primary font covers them with
        // a monochrome glyph. Resolve them against the Apple Color Emoji
        // face directly — bypassing both the primary-font fast path below
        // and the per-256-block resolver cache (which a text-default
        // neighbor in the same block, e.g. ⚠ U+26A0 in block 0x26, could
        // have poisoned with a non-emoji font). Astral emoji scalars skip
        // this — they already resolve to AppleColorEmoji via the cascade
        // because the primary font lacks them — so the guard keeps the
        // BMP-only `CTFontGetGlyphsForCharacters` contract. If the color
        // face somehow lacks the glyph, fall through to the normal paths.
        if Self.prefersColorPresentation(scalar), scalar.value <= 0xFFFF {
            var ch = UniChar(scalar.value)
            var glyph: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(
                emojiPresentationFont, &ch, &glyph, 1), glyph != 0
            {
                return (glyph, emojiPresentationFont)
            }
        }

        // BMP fast path — try the primary font first. Astrals fall
        // through unconditionally (their UTF-16 representation needs
        // a surrogate pair, which `CTFontGetGlyphsForCharacters` won't
        // synthesize from a single UniChar input).
        if scalar.value <= 0xFFFF {
            var ch = UniChar(scalar.value)
            var glyph: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(self.font, &ch, &glyph, 1)
                && glyph != 0
            {
                return (glyph, self.font)
            }
        }

        // Fallback path. CoreText always returns a font (LastResort
        // in the genuinely-unknown case — never nil).
        let resolvedFont = resolveFont(for: scalar)
        // Encode the scalar as UTF-16. BMP scalars produce one unit;
        // astrals produce a high+low surrogate pair. Use Swift's
        // built-in encoding rather than CFString round-tripping —
        // `String(scalar).utf16` is a static two-or-fewer-element
        // sequence with no allocation in the common case.
        var chars: [UniChar] = []
        chars.reserveCapacity(2)
        for unit in String(scalar).utf16 { chars.append(unit) }
        let count = chars.count
        var glyphs = [CGGlyph](repeating: 0, count: count)
        let ok = chars.withUnsafeBufferPointer { cb -> Bool in
            glyphs.withUnsafeMutableBufferPointer { gb -> Bool in
                CTFontGetGlyphsForCharacters(
                    resolvedFont, cb.baseAddress!, gb.baseAddress!, count)
            }
        }
        // For surrogate pairs `CTFontGetGlyphsForCharacters` writes
        // the composed glyph into glyphs[0] and zero into glyphs[1]
        // (the trailing-surrogate slot collapses into the lead). We
        // take glyphs[0] either way. Real grapheme-cluster shaping
        // (combining marks, ZWJ sequences) is M2+ shape-cache work.
        if ok, glyphs[0] != 0 {
            return (glyphs[0], resolvedFont)
        }
        // CoreText returned a font but couldn't map the scalar to a
        // glyph in it. Should be unreachable — LastResort always
        // produces a hex-code "tofu" rectangle — but defensive.
        throw AtlasError.glyphMissing(scalar)
    }

    /// Resolve the best font for `scalar` via
    /// `CTFontCreateForStringWithLanguage`, memoized per 256-codepoint
    /// block. Always returns a non-nil font (CoreText falls back to
    /// LastResort in the truly-unknown case). The primary font fast
    /// path is handled by `resolveGlyph`; this method is only called
    /// for cache misses.
    func resolveFont(for scalar: Unicode.Scalar) -> CTFont {
        let block = scalar.value >> 8
        if let cached = fontCacheByBlock[block] { return cached }

        let cf = String(scalar) as CFString
        let length = CFStringGetLength(cf)
        let range = CFRange(location: 0, length: length)
        // Pass `nil` for language — CoreText picks based on the
        // scalar's script properties, which is the right default for
        // terminal traffic. Language hints ("zh", "ja") would only
        // change behaviour for Han-unified codepoints where the
        // glyph form differs between Chinese and Japanese; that's
        // M2+ territory (per-locale font config).
        let resolved = CTFontCreateForStringWithLanguage(
            self.font, cf, range, nil)
        fontCacheByBlock[block] = resolved
        return resolved
    }

    struct RasterizedGlyph {
        let bitmap: [UInt8]
        let widthPx: Int
        let heightPx: Int
        let bearingPx: SIMD2<Int32>
    }

    /// Uniform downscale factor (≤ 1, aspect-preserving) so a CoreText
    /// glyph bounding box `bbox` (in points, pen origin at x=0 on the
    /// baseline) fits entirely inside a target box `boxWidthPt` wide,
    /// with `cellAscentPt` of headroom above the baseline and
    /// `cellDescentPt` below. Returns 1.0 when the glyph already fits
    /// (so the common ASCII/CJK path stays bit-identical — no atlas
    /// snapshot or metric drift), and never upscales.
    ///
    /// Covers BOTH axes plus overflow in either direction: the ink spans
    /// `[bbox.minX, bbox.maxX]` horizontally (left-side bearing may be
    /// negative) and `[bbox.minY, bbox.maxY]` vertically (descenders sit
    /// below the baseline at y<0, ascenders above at y>maxY). Each
    /// potential overflow contributes a candidate scale; the smallest
    /// wins.
    ///
    /// Powerline / Nerd-Font cell-bleed glyphs (separators *designed* to
    /// touch the cell edge) are unaffected: ink that exactly reaches the
    /// box edge yields ratio == 1.0, so the min stays 1.0 and no scaling
    /// occurs. Only glyphs that genuinely exceed the box shrink.
    static func fitScale(
        bbox: CGRect,
        boxWidthPt: CGFloat,
        cellAscentPt: CGFloat,
        cellDescentPt: CGFloat
    ) -> CGFloat {
        var scale: CGFloat = 1.0
        // Horizontal: right overflow past the box edge.
        if bbox.maxX > boxWidthPt, bbox.maxX > 0 {
            scale = min(scale, boxWidthPt / bbox.maxX)
        }
        // Left-side bearing pushes ink left of the pen; bound the total
        // ink width so nothing clips at x<0.
        if bbox.minX < 0 {
            let inkWidth = bbox.maxX - bbox.minX
            if inkWidth > boxWidthPt, inkWidth > 0 {
                scale = min(scale, boxWidthPt / inkWidth)
            }
        }
        // Vertical: ascender above the cell ascent (the original Thai
        // SARA AM constraint), descender below the cell descent.
        if bbox.maxY > cellAscentPt, bbox.maxY > 0 {
            scale = min(scale, cellAscentPt / bbox.maxY)
        }
        if bbox.minY < -cellDescentPt, bbox.minY < 0 {
            scale = min(scale, cellDescentPt / -bbox.minY)
        }
        return scale
    }

    func rasterize(
        glyphId: CGGlyph, font: CTFont
    ) throws -> RasterizedGlyph {
        let widthPx = Int(cellSizePx.x)
        let heightPx = Int(cellSizePx.y)

        // Fit-to-box: when the resolved fallback font draws a glyph that
        // overflows the cell — above the ascent (e.g. SARA AM ำ's
        // NIKHAHIT circle, MAI HAN-AKAT + tone stacks, tall CJK), below
        // the descent, or past the left/right edge (wide fallback
        // symbols, color-glyph-shaped Dingbats resolved into the gray
        // path) — the cell-sized bitmap clips it. Scale the font down
        // uniformly so the ink fits. Glyph IDs are stable across
        // same-face size changes so the existing glyph ID still resolves
        // in the scaled copy. A glyph that already fits gets scale==1.0
        // and is left untouched (the common ASCII/CJK path is
        // bit-identical).
        let cellAscentPt = CTFontGetAscent(self.font)
        let cellDescentPt = CTFontGetDescent(self.font)
        let boxWidthPt = CGFloat(cellSizePx.x) / contentsScale
        var renderFont = font
        var bbox = CGRect.zero
        var localGlyph = glyphId
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &localGlyph, &bbox, 1)
        let scale = Self.fitScale(
            bbox: bbox,
            boxWidthPt: boxWidthPt,
            cellAscentPt: cellAscentPt,
            cellDescentPt: cellDescentPt)
        if scale < 1.0 {
            let newSize = CTFontGetSize(font) * scale
            renderFont = CTFontCreateCopyWithAttributes(font, newSize, nil, nil) ?? font
        }

        var bitmap = [UInt8](repeating: 0, count: widthPx * heightPx)

        // Color emoji (AppleColorEmoji) is dispatched in `entry(for:)`
        // BEFORE reaching this function — it goes through the dedicated
        // RGBA color atlas instead. This path is grayscale-only.
        let success: Bool = bitmap.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                let ctx = CGContext(
                    data: base,
                    width: widthPx,
                    height: heightPx,
                    bitsPerComponent: 8,
                    bytesPerRow: widthPx,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldSmoothFonts(false)  // grayscale, no subpixel
            ctx.setFillColor(gray: 1.0, alpha: 1.0)
            ctx.scaleBy(x: contentsScale, y: contentsScale)
            let descent = CTFontGetDescent(renderFont)
            var pos = CGPoint(x: 0, y: descent)
            var drawGlyph = glyphId
            CTFontDrawGlyphs(renderFont, &drawGlyph, &pos, 1, ctx)
            return true
        }
        guard success else { throw AtlasError.rasterizationFailed }

        // Compute the glyph's bounding rect in pixel space for bearing
        // — use the post-scale font so the bearing matches what we
        // actually drew.
        var rectGlyph = glyphId
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(renderFont, .horizontal, &rectGlyph, &rect, 1)
        let bearingX = Int32(round(rect.minX * contentsScale))
        let bearingY = Int32(round(rect.minY * contentsScale))

        // The CG transform above flipped the coordinate system so the
        // glyph is drawn directly into the bitmap's row-major top-down
        // memory layout, matching Metal's top-left atlas sampling.
        // No post-rasterization flip is needed.
        return RasterizedGlyph(
            bitmap: bitmap,
            widthPx: widthPx,
            heightPx: heightPx,
            bearingPx: SIMD2(bearingX, bearingY))
    }

    // MARK: - Pinned blank slot

    /// Reserve atlas position (0, 0) as the canonical "blank" slot.
    /// `GridPipeline.setGrid/setRegion/setCell` write `(0, 0)` UV for
    /// cells with `slot.glyph == nil`; the shader samples that and
    /// expects alpha=0 (the texture is zero-initialized in private
    /// storage). Pre-rasterizing any glyph at (0, 0) would make every
    /// blank cell render that glyph tinted to the cell's fg.
    ///
    /// Reservation width = `cellSizePx.x + 1` (one full cell + a
    /// 1-texel guard). The +1 is load-bearing: the shader uses
    /// `linear` filter on the atlas (Shaders.metal:154) so a blank
    /// cell sampling UVs in [0, cellSize/atlasSize] bleeds into the
    /// texel at exactly `cellSize` via the linear interpolation tap.
    /// Without the guard, the first rasterized glyph at x=cellSize
    /// tints every blank cell ~50 %.
    ///
    /// Pinned per task 4.2: LRU eviction MUST NOT recycle this rect,
    /// and the fragmentation-cliff full-reset MUST re-pin it.
    func pinBlankSlot() {
        let blankWidth = cellSizePx.x + 1
        let blankHeight = cellSizePx.y
        pinnedRegions.append(
            PinnedRegion(
                originPx: SIMD2(0, 0),
                sizePx: SIMD2(blankWidth, blankHeight)))
        // Initialise the shelf cursor past the pinned region so the
        // first allocation lands at `(blankWidth, 0)`. shelfHeight
        // matches so subsequent glyphs share the row until wrap.
        shelfX = blankWidth
        shelfY = 0
        shelfHeight = blankHeight

        // Explicit-zero the pinned region. Apple Silicon does NOT
        // guarantee zero-init for `.private` storage textures; initial
        // contents are documented as undefined. Without this upload,
        // blank-cell sampling at UV ≈ (0, 0) reads garbage — commonly
        // returning alpha ≈ 1, which makes the grid shader's
        // `mix(bg, fg, alpha)` produce text-primary instead of bg-base
        // for every untouched cell. The whole content area would
        // appear in the foreground color.
        //
        // Private storage requires a blit upload via a staging buffer;
        // direct `texture.replace(region:)` raises EXC_BAD_ACCESS.
        let widthInt = Int(blankWidth)
        let heightInt = Int(blankHeight)
        let length = widthInt * heightInt
        if let queue = device.makeCommandQueue(),
            let staging = device.makeBuffer(
                length: length, options: [.storageModeShared])
        {
            staging.label = "GlyphAtlas pin-blank zero staging"
            let stagingPtr = staging.contents()
                .bindMemory(to: UInt8.self, capacity: length)
            for i in 0..<length { stagingPtr[i] = 0 }
            if let buffer = queue.makeCommandBuffer(),
                let blit = buffer.makeBlitCommandEncoder()
            {
                buffer.label = "GlyphAtlas pin-blank zero blit"
                blit.copy(
                    from: staging,
                    sourceOffset: 0,
                    sourceBytesPerRow: widthInt,
                    sourceBytesPerImage: length,
                    sourceSize: MTLSize(
                        width: widthInt, height: heightInt, depth: 1),
                    to: texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
                buffer.commit()
                buffer.waitUntilCompleted()
            }
        }
    }
}
