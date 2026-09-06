// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// The rgba8Unorm color-emoji atlas for `GlyphAtlas`, split out of the
// single-file atlas along its existing MARKs: the parallel allocator +
// uploader (same shelf-pack + LRU + reset semantics as the gray atlas,
// on independent state) and the color-atlas public surface used as a
// test seam. Stored properties live in GlyphAtlas.swift because
// extensions cannot declare them.

import CoreText
import Foundation
import Metal

extension GlyphAtlas {
    // MARK: - Color atlas (A-emoji-1)
    //
    // Parallel allocator + uploader for the rgba8Unorm color emoji
    // atlas. Same shelf-pack + LRU + reset semantics as the gray
    // atlas; independent state so emoji evictions can't displace
    // ASCII glyphs. Atomic 4 wires `entry(for:)` / cluster path to
    // route AppleColorEmoji here; atomics 1-3 keep this surface
    // standalone (covered by tests).

    /// Rasterize a color emoji glyph into an RGBA8 buffer
    /// (premultipliedLast). The buffer is `cellWidthPx × cellHeightPx ×
    /// 4` bytes. Bearing is computed from the glyph's bbox in the
    /// passed-in font (post any future scale adjustments).
    struct RasterizedColorGlyph {
        let bytes: [UInt8]  // RGBA premultipliedLast
        let widthPx: Int
        let heightPx: Int
        let bearingPx: SIMD2<Int32>
    }

    func rasterizeColor(
        glyphId: CGGlyph, font: CTFont
    ) throws -> RasterizedColorGlyph {
        let widthPx = Int(cellSizePx.x)
        let heightPx = Int(cellSizePx.y)
        let bytesPerRow = widthPx * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * heightPx)

        // Fit-to-box (same contract as the gray `rasterize` path). A
        // single-scalar color emoji the engine reports as width-1 can
        // still carry a glyph wider or taller than one cell (most Apple
        // Color Emoji are square-ish but a few resolve slightly past the
        // monospace cell). Without this, the sbix bitmap clips at the
        // right/top edge. Scale the AppleColorEmoji font copy down so the
        // glyph fits one cell; a glyph that already fits gets scale==1.0
        // and renders unchanged.
        let cellAscentPt = CTFontGetAscent(self.font)
        let cellDescentPt = CTFontGetDescent(self.font)
        let boxWidthPt = CGFloat(cellSizePx.x) / contentsScale
        var renderFont = font
        var bbox = CGRect.zero
        var measureGlyph = glyphId
        CTFontGetBoundingRectsForGlyphs(
            font, .horizontal, &measureGlyph, &bbox, 1)
        let scale = Self.fitScale(
            bbox: bbox,
            boxWidthPt: boxWidthPt,
            cellAscentPt: cellAscentPt,
            cellDescentPt: cellDescentPt)
        if scale < 1.0 {
            let newSize = CTFontGetSize(font) * scale
            renderFont =
                CTFontCreateCopyWithAttributes(font, newSize, nil, nil) ?? font
        }

        let drew: Bool = bytes.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                let ctx = CGContext(
                    data: base,
                    width: widthPx,
                    height: heightPx,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)
            ctx.scaleBy(x: contentsScale, y: contentsScale)
            let descent = CTFontGetDescent(renderFont)
            var pos = CGPoint(x: 0, y: descent)
            var localGlyph = glyphId
            CTFontDrawGlyphs(renderFont, &localGlyph, &pos, 1, ctx)
            return true
        }
        guard drew else { throw AtlasError.rasterizationFailed }

        var rectGlyph = glyphId
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(
            renderFont, .horizontal, &rectGlyph, &rect, 1)
        let bearingX = Int32(round(rect.minX * contentsScale))
        let bearingY = Int32(round(rect.minY * contentsScale))

        return RasterizedColorGlyph(
            bytes: bytes,
            widthPx: widthPx,
            heightPx: heightPx,
            bearingPx: SIMD2(bearingX, bearingY))
    }

    /// Color-atlas counterpart to `place(raster:queue:)`. Allocates a
    /// rect in the color atlas via the parallel shelf allocator and
    /// blits the RGBA buffer to `colorTexture`.
    func placeColor(
        raster: RasterizedColorGlyph, queue: MTLCommandQueue
    ) throws -> AtlasEntry {
        let w = UInt32(raster.widthPx)
        let h = UInt32(raster.heightPx)
        let bytes = UInt64(w) * UInt64(h) * Self.colorBytesPerPixel

        // 64 MiB hard ceiling check shared with the gray atlas — the
        // production 1024² × 4 B = 4 MiB color atlas can't approach it
        // even when fully populated, but the contract is pinned.
        if bytesAllocated + colorBytesAllocated + bytes > Self.maxBytes {
            throw AtlasError.bytesCeilingExceeded(
                needed: bytesAllocated + colorBytesAllocated + bytes,
                ceiling: Self.maxBytes)
        }

        let origin = try allocateColorOrigin(width: w, height: h, queue: queue)

        try uploadColorBitmap(
            raster.bytes,
            widthPx: raster.widthPx,
            heightPx: raster.heightPx,
            originX: origin.x,
            originY: origin.y,
            queue: queue)

        colorBytesAllocated += bytes
        return AtlasEntry(
            originPx: origin,
            sizePx: SIMD2(w, h),
            bearingPx: raster.bearingPx,
            atlasIndex: 1)
    }

    /// Mirrors `allocateOrigin` but against the color-atlas state.
    /// Eviction picks the LRU entry from `colorEntries`; reset clears
    /// only the color side, leaving the gray atlas alone.
    private func allocateColorOrigin(
        width w: UInt32, height h: UInt32, queue: MTLCommandQueue
    ) throws -> SIMD2<UInt32> {
        if let origin = takeFromColorFreeList(width: w, height: h) {
            return origin
        }
        if let origin = advanceColorShelf(width: w, height: h) {
            return origin
        }
        while evictOneColorLRU() {
            if let origin = takeFromColorFreeList(width: w, height: h) {
                return origin
            }
        }
        if colorEntries.contains(where: { $0.value.lastAccess > frameAccessFloor }) {
            throw AtlasError.atlasFull(needed: SIMD2(w, h))
        }
        NSLog(
            "GlyphAtlas: color atlas fragmentation cliff — reset (needed %ux%u)",
            w, h)
        resetColorAtlas()
        if let origin = advanceColorShelf(width: w, height: h) {
            return origin
        }
        throw AtlasError.atlasFull(needed: SIMD2(w, h))
    }

    private func takeFromColorFreeList(
        width w: UInt32, height h: UInt32
    ) -> SIMD2<UInt32>? {
        for i in 0..<colorFreeRects.count
        where colorFreeRects[i].sizePx.x >= w && colorFreeRects[i].sizePx.y >= h {
            let rect = colorFreeRects.remove(at: i)
            return rect.originPx
        }
        return nil
    }

    private func advanceColorShelf(
        width w: UInt32, height h: UInt32
    ) -> SIMD2<UInt32>? {
        var x = colorShelfX
        var y = colorShelfY
        var shelfH = colorShelfHeight
        if x + w > colorAtlasSize.x {
            y += shelfH
            x = 0
            shelfH = 0
        }
        if y + h > colorAtlasSize.y {
            return nil
        }
        let originX = x
        let originY = y
        colorShelfX = x + w
        colorShelfY = y
        colorShelfHeight = max(shelfH, h)
        return SIMD2(originX, originY)
    }

    @discardableResult
    private func evictOneColorLRU() -> Bool {
        // Same batch-pinning rule as the gray atlas: don't evict a glyph
        // touched this resolve batch (lastAccess > frameAccessFloor).
        guard
            let victim = colorEntries.lazy
                .filter({ $0.value.lastAccess <= self.frameAccessFloor })
                .min(by: { $0.value.lastAccess < $1.value.lastAccess })
        else { return false }
        let entry = victim.value.entry
        colorEntries.removeValue(forKey: victim.key)
        colorFreeRects.append(
            FreeRect(originPx: entry.originPx, sizePx: entry.sizePx))
        let bytes =
            UInt64(entry.sizePx.x) * UInt64(entry.sizePx.y)
            * Self.colorBytesPerPixel
        colorBytesAllocated =
            colorBytesAllocated >= bytes
            ? colorBytesAllocated - bytes : 0
        pendingEviction = true
        return true
    }

    private func resetColorAtlas() {
        colorEntries.removeAll(keepingCapacity: true)
        colorFreeRects.removeAll(keepingCapacity: true)
        colorBytesAllocated = 0
        colorShelfX = 0
        colorShelfY = 0
        colorShelfHeight = 0
        pendingEviction = true
    }

    private func uploadColorBitmap(
        _ bytes: [UInt8],
        widthPx: Int,
        heightPx: Int,
        originX: UInt32,
        originY: UInt32,
        queue: MTLCommandQueue
    ) throws {
        let length = widthPx * heightPx * 4
        guard
            let staging = device.makeBuffer(
                length: length, options: [.storageModeShared])
        else {
            throw AtlasError.textureAllocFailed
        }
        staging.label = "GlyphAtlas color staging"
        let stagingPtr = staging.contents().bindMemory(
            to: UInt8.self, capacity: length)
        for i in 0..<length { stagingPtr[i] = bytes[i] }

        guard let buffer = queue.makeCommandBuffer() else {
            throw AtlasError.rasterizationFailed
        }
        buffer.label = "GlyphAtlas color blit upload"
        guard let encoder = buffer.makeBlitCommandEncoder() else {
            throw AtlasError.rasterizationFailed
        }
        encoder.copy(
            from: staging,
            sourceOffset: 0,
            sourceBytesPerRow: widthPx * 4,
            sourceBytesPerImage: length,
            sourceSize: MTLSize(width: widthPx, height: heightPx, depth: 1),
            to: colorTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(
                x: Int(originX), y: Int(originY), z: 0))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    // MARK: - Color-atlas public surface (test seam)

    /// Look up or rasterize-and-insert a single color glyph (Apple
    /// Color Emoji single-codepoint). Standalone API used by tests
    /// at A-emoji-1. The `entry(for:)` routing path that swaps this
    /// in for emoji scalars lands at A-emoji-4.
    func colorEntry(
        for scalar: Unicode.Scalar, commandQueue: MTLCommandQueue
    ) throws -> AtlasEntry {
        let font = resolveFont(for: scalar)
        // Astral-plane emoji (e.g. 🎉 U+1F389) need surrogate-pair
        // UTF-16 encoding for `CTFontGetGlyphsForCharacters` — passing
        // `UniChar(scalar.value)` overflows UInt16 and traps. Mirrors
        // the encoding pattern in `resolveGlyph`'s fallback branch.
        var chars: [UniChar] = []
        chars.reserveCapacity(2)
        for unit in String(scalar).utf16 { chars.append(unit) }
        let count = chars.count
        var glyphs = [CGGlyph](repeating: 0, count: count)
        _ = chars.withUnsafeBufferPointer { cb -> Bool in
            glyphs.withUnsafeMutableBufferPointer { gb -> Bool in
                CTFontGetGlyphsForCharacters(
                    font, cb.baseAddress!, gb.baseAddress!, count)
            }
        }
        // Surrogate pair returns the primary glyph at index 0.
        let glyph = glyphs[0]
        let resolvedFontHash = cachedFontHash(for: font)
        let key = GlyphKey(
            fontHash: resolvedFontHash,
            glyphId: UInt32(glyph),
            pxSize: UInt16(
                round(min(CTFontGetSize(font) * 100, Double(UInt16.max)))),
            contentsScale: UInt8(contentsScale))

        accessCounter &+= 1
        if var cached = colorEntries[key] {
            cached.lastAccess = accessCounter
            colorEntries[key] = cached
            return cached.entry
        }

        let raster = try rasterizeColor(glyphId: glyph, font: font)
        let entry = try placeColor(raster: raster, queue: commandQueue)
        colorEntries[key] = Record(entry: entry, lastAccess: accessCounter)
        return entry
    }

    /// Read-only accessors for tests.
    var colorEntryCount: Int { colorEntries.count }
    var colorBytesAllocatedForTesting: UInt64 { colorBytesAllocated }
}
