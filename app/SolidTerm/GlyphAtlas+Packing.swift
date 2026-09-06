// Shelf packing, LRU eviction and blit upload for `GlyphAtlas`, split
// out of the single-file atlas along its existing MARK: the gray-atlas
// allocator (`place`, `allocateOrigin`, the free list, the shelf
// advance), the LRU victim scan, the wholesale atlas reset, and the
// staging-buffer → texture blit. Stored properties live in
// GlyphAtlas.swift because extensions cannot declare them.

import Foundation
import Metal

extension GlyphAtlas {
    // MARK: - Shelf packer + LRU eviction + blit upload

    func place(raster: RasterizedGlyph, queue: MTLCommandQueue) throws -> AtlasEntry {
        let w = UInt32(raster.widthPx)
        let h = UInt32(raster.heightPx)
        let bytes = UInt64(w) * UInt64(h) * Self.bytesPerPixel

        // Hard ceiling check — defensive at the production 512² shelf
        // (unreachable in practice) but contract-pinned for post-M1. The
        // 64 MiB ceiling is SHARED with the color atlas, so account for
        // both sides here (placeColor does the same); checking only
        // bytesAllocated would let gray + color together exceed it once
        // the post-M1 4096² heaps make the ceiling load-bearing.
        if bytesAllocated + colorBytesAllocated + bytes > Self.maxBytes {
            throw AtlasError.bytesCeilingExceeded(
                needed: bytesAllocated + colorBytesAllocated + bytes,
                ceiling: Self.maxBytes)
        }

        let origin = try allocateOrigin(width: w, height: h, queue: queue)

        try uploadBitmap(
            raster.bitmap,
            widthPx: raster.widthPx,
            heightPx: raster.heightPx,
            originX: origin.x,
            originY: origin.y,
            queue: queue)

        bytesAllocated += bytes
        return AtlasEntry(
            originPx: origin,
            sizePx: SIMD2(w, h),
            bearingPx: raster.bearingPx)
    }

    /// Try the free-list, then shelf advance, then LRU eviction. If
    /// even evicting all evictable entries can't yield a fitting rect
    /// (free-list fragmentation), reset the atlas wholesale and retry.
    func allocateOrigin(
        width w: UInt32, height h: UInt32, queue: MTLCommandQueue
    ) throws -> SIMD2<UInt32> {
        if let origin = takeFromFreeList(width: w, height: h) {
            return origin
        }
        if let origin = advanceShelf(width: w, height: h) {
            return origin
        }
        // Shelf is full. Evict LRU entries one at a time, refunding
        // their rects to the free list, until either (a) the free
        // list serves the request or (b) we run out of evictable
        // entries.
        while evictOneLRU() {
            if let origin = takeFromFreeList(width: w, height: h) {
                return origin
            }
        }
        // No evictable (pre-batch) entry remains. If glyphs resolved THIS
        // batch still occupy the atlas, the frame's working set exceeds
        // capacity — resetting would free their rects and alias the
        // already-resolved CellSlots (garble). Fail safe: this glyph
        // renders blank. (Cure = a larger atlas; tracked tech-debt.)
        if entries.contains(where: { $0.value.lastAccess > frameAccessFloor }) {
            throw AtlasError.atlasFull(needed: SIMD2(w, h))
        }
        // Free-list fragmentation cliff: only stale entries remained and
        // the request still won't fit. Reset wholesale and try once more.
        // A reset re-pins the blank slot.
        NSLog(
            "GlyphAtlas: fragmentation cliff — full atlas reset (needed %ux%u)",
            w, h)
        resetAtlas()
        if let origin = advanceShelf(width: w, height: h) {
            return origin
        }
        // The reset cleared shelf state too — if even a fresh atlas
        // can't fit the request, the glyph is genuinely too large for
        // this atlas. (Unreachable at the cell-sized rasters we
        // currently emit; defensive.)
        throw AtlasError.atlasFull(needed: SIMD2(w, h))
    }

    /// First-fit scan over `freeRects`. Returns the rect's origin and
    /// removes it from the list on hit. Any-fit is fine: cells are
    /// uniform-sized at this scale so first-fit is also best-fit.
    private func takeFromFreeList(width w: UInt32, height h: UInt32) -> SIMD2<UInt32>? {
        for i in 0..<freeRects.count
        where freeRects[i].sizePx.x >= w && freeRects[i].sizePx.y >= h {
            let rect = freeRects.remove(at: i)
            return rect.originPx
        }
        return nil
    }

    /// Wrap to the next shelf if needed; bail with nil if the next
    /// shelf overflows the texture height. Caller decides whether to
    /// trigger eviction or reset.
    private func advanceShelf(width w: UInt32, height h: UInt32) -> SIMD2<UInt32>? {
        var x = shelfX
        var y = shelfY
        var shelfH = shelfHeight
        if x + w > atlasSize.x {
            y += shelfH
            x = 0
            shelfH = 0
        }
        if y + h > atlasSize.y {
            return nil
        }
        let originX = x
        let originY = y
        shelfX = x + w
        shelfY = y
        shelfHeight = max(shelfH, h)
        return SIMD2(originX, originY)
    }

    /// Evict the single oldest (lowest `lastAccess`) entry, refunding
    /// its rect to the free list. Pinned regions are never in
    /// `entries`, so they're inherently safe.
    /// Evict the least-recently-used entry that is NOT pinned by the
    /// current resolve batch (`lastAccess <= frameAccessFloor`). Returns
    /// `false` when no such entry exists — the caller must NOT then reset
    /// or alias the remaining (this-batch) entries.
    @discardableResult
    private func evictOneLRU() -> Bool {
        guard
            let victim = entries.lazy
                .filter({ $0.value.lastAccess <= self.frameAccessFloor })
                .min(by: { $0.value.lastAccess < $1.value.lastAccess })
        else { return false }
        let rect = victim.value.entry
        freeRects.append(
            FreeRect(originPx: rect.originPx, sizePx: rect.sizePx))
        let bytes = UInt64(rect.sizePx.x) * UInt64(rect.sizePx.y) * Self.bytesPerPixel
        bytesAllocated -= min(bytesAllocated, bytes)
        entries.removeValue(forKey: victim.key)
        pendingEviction = true
        return true
    }

    /// Full-atlas reset: clear all entries + free-list, reset shelf
    /// cursor, re-pin the blank slot. Used as the fragmentation-cliff
    /// fallback. The texture itself is not zeroed — newly-allocated
    /// regions are unconditionally overwritten by the next blit. The
    /// pinned `(0,0)` blank region was never written by anything other
    /// than the zero-init of the private-storage texture, so its
    /// alpha=0 contract is preserved across the reset.
    private func resetAtlas() {
        entries.removeAll(keepingCapacity: true)
        freeRects.removeAll(keepingCapacity: true)
        pinnedRegions.removeAll(keepingCapacity: true)
        bytesAllocated = 0
        shelfX = 0
        shelfY = 0
        shelfHeight = 0
        pinBlankSlot()
        pendingEviction = true
    }

    private func uploadBitmap(
        _ bytes: [UInt8],
        widthPx: Int,
        heightPx: Int,
        originX: UInt32,
        originY: UInt32,
        queue: MTLCommandQueue
    ) throws {
        let length = widthPx * heightPx
        guard
            let staging = device.makeBuffer(length: length, options: [.storageModeShared])
        else {
            throw AtlasError.textureAllocFailed
        }
        staging.label = "GlyphAtlas staging"
        let stagingPtr = staging.contents().bindMemory(to: UInt8.self, capacity: length)
        for i in 0..<length { stagingPtr[i] = bytes[i] }

        guard let buffer = queue.makeCommandBuffer() else {
            throw AtlasError.rasterizationFailed
        }
        buffer.label = "GlyphAtlas blit upload"
        guard let encoder = buffer.makeBlitCommandEncoder() else {
            throw AtlasError.rasterizationFailed
        }
        encoder.copy(
            from: staging,
            sourceOffset: 0,
            sourceBytesPerRow: widthPx,
            sourceBytesPerImage: length,
            sourceSize: MTLSize(width: widthPx, height: heightPx, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: Int(originX), y: Int(originY), z: 0))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }
}
