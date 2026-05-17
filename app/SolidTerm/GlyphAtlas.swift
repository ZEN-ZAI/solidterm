// Atlas LRU eviction — algorithm ported from Alacritty's
// `alacritty/src/renderer/text/atlas.rs` (Apache-2.0). Original
// copyright Joe Wilm and contributors; see
// <https://github.com/alacritty/alacritty/blob/master/alacritty/src/renderer/text/atlas.rs>.
// The shelf-packing + LRU pattern is structural; the Swift
// implementation against Metal is original.
//
// Implements spec/metal-renderer.md §Glyph atlas.
//
// Stage 1: shelf-packed bitmap atlas with LRU eviction (M1 task 4.2).
// Single grayscale `MTLTexture` (.r8Unorm, 512×512), shelf-packed,
// uploaded via a shared-storage staging buffer + `MTLBlitCommandEncoder`
// per spec line 167. CoreText rasterizes each glyph into a CPU
// `CGContext` (deviceGray, 8 bpp) before the upload. Eviction recycles
// rects via a free-list; on fragmentation the atlas resets wholesale
// and re-pins its blank slot.
//
// Stage 2 (M1 task 4.3): per-scalar font fallback via
// `CTFontCreateForStringWithLanguage`. When the primary font (e.g.
// Menlo) lacks a glyph for a scalar, CoreText resolves a fallback
// (PingFang for Han, Thonburi for Thai, Apple Color Emoji for
// emoji, LastResort for the genuinely unknown). Each fallback's
// glyphs share the atlas keyed by `GlyphKey.fontHash`. Fallback
// fonts are cached per 256-codepoint Unicode block so a CJK
// paragraph doesn't pay the resolver cost on every cell.
//
// Out of scope (deferred to post-M1; tracked in tech-debt.md):
// MTLHeap private storage with 64 MiB ceiling, 4096² grayscale +
// 2048² color-emoji dual atlas (color emoji rasterizes to grayscale
// tofu in the current r8Unorm atlas — Apple Color Emoji is a
// bitmap-color font and our shader samples a single channel),
// intrusive doubly-linked list for O(1) LRU operations, deferred
// between-frames GC step, background rasterization on a GCD queue,
// shape cache, subpixel binning, surrogate-pair grapheme-cluster
// shaping, bold/italic font selection.

import CoreText
import Foundation
import Metal

/// A pixel rect inside the atlas texture, plus the [0,1] UV box used by
/// the fragment shader. Sizes are in **device pixels**, not points.
///
/// `atlasIndex` identifies which atlas texture the entry lives in: 0 =
/// grayscale (r8Unorm, primary path for monospace glyphs), 1 = color
/// emoji (rgba8Unorm, AppleColorEmoji sbix bitmaps). The renderer reads
/// this to bind the right sampler in the fragment shader; defaults to
/// 0 so existing call sites stay unchanged.
///
/// `cellSpan` is the number of terminal columns this glyph paints
/// across — 1 for a single-cell glyph (ASCII, single Han, single
/// emoji-fallback cell), N for a coalesced cross-cell grapheme cluster
/// (Thai consonant + SARA AM, regional indicator flag pair, ZWJ
/// spillover). See ADR-19 + spec/cross-cell-shaping.md. Defaults to 1
/// so single-glyph call sites stay unchanged; the cluster path passes
/// the value computed by `GraphemeClusterCoalescer`.
struct AtlasEntry {
    let originPx: SIMD2<UInt32>
    let sizePx: SIMD2<UInt32>
    let bearingPx: SIMD2<Int32>  // glyph offset from cell top-left
    var atlasIndex: UInt8 = 0
    var cellSpan: UInt8 = 1

    init(
        originPx: SIMD2<UInt32>,
        sizePx: SIMD2<UInt32>,
        bearingPx: SIMD2<Int32>,
        atlasIndex: UInt8 = 0,
        cellSpan: UInt8 = 1
    ) {
        self.originPx = originPx
        self.sizePx = sizePx
        self.bearingPx = bearingPx
        self.atlasIndex = atlasIndex
        self.cellSpan = cellSpan
    }
}

extension AtlasEntry {
    /// UV rectangle for the fragment shader. Origin is top-left in atlas
    /// space (Metal default for `texture2d.sample`).
    func uvOrigin(atlasSize: SIMD2<UInt32>) -> SIMD2<Float> {
        SIMD2(
            Float(originPx.x) / Float(atlasSize.x),
            Float(originPx.y) / Float(atlasSize.y))
    }

    func uvSize(atlasSize: SIMD2<UInt32>) -> SIMD2<Float> {
        SIMD2(
            Float(sizePx.x) / Float(atlasSize.x),
            Float(sizePx.y) / Float(atlasSize.y))
    }
}

struct GlyphKey: Hashable {
    let fontHash: UInt64
    let glyphId: UInt32
    let pxSize: UInt16  // size × 100 (hundredths of a point)
    let contentsScale: UInt8  // 1 or 2 — Retina vs non-Retina
}

final class GlyphAtlas {
    /// Production atlas dimensions in pixels. 512 × 512 × 1 B = 256 KB.
    /// Heap-backed 4096² version arrives post-M1 alongside the dual
    /// (color emoji) atlas — see tech-debt.md.
    static let atlasSize: SIMD2<UInt32> = SIMD2(512, 512)

    /// Color emoji atlas dimensions. 1024 × 1024 × 4 B = 4 MiB —
    /// compromise between the spec's 2048² (16 MiB) and the gray
    /// atlas's 512² (1 MiB equivalent at RGBA). Holds ~hundreds of
    /// emoji cells before LRU eviction kicks in, which covers a
    /// typical Claude Code dogfood session without thrashing.
    static let defaultColorAtlasSize: SIMD2<UInt32> = SIMD2(1024, 1024)

    /// Bytes per pixel of the color atlas (rgba8Unorm = 4).
    private static let colorBytesPerPixel: UInt64 = 4

    /// Hard ceiling on bytes-allocated tracked across the atlas
    /// texture. The production 512² shelf can never breach this — the
    /// assertion is a contract pin per the M1 task 4.2 acceptance gate
    /// and a guardrail when the post-M1 4096² migration lands.
    static let maxBytes: UInt64 = 64 * 1024 * 1024  // 64 MiB

    let device: MTLDevice
    let texture: MTLTexture
    /// Color emoji atlas (rgba8Unorm, 1024² by default). Sibling to the
    /// primary `texture` (r8Unorm grayscale). Apple Color Emoji is a
    /// bitmap-color font (sbix tables) — its glyphs only rasterize into
    /// RGBA contexts, and the renderer samples them as full RGBA
    /// (passthrough, no fg-tint) via the shader's selector branch.
    ///
    /// Sized smaller than the gray atlas because emoji cardinality is
    /// far lower in real terminal sessions; LRU eviction handles the
    /// long tail.
    let colorTexture: MTLTexture
    let colorAtlasSize: SIMD2<UInt32>
    let cellSizePx: SIMD2<UInt32>
    let cellSizePt: CGSize
    let font: CTFont
    let contentsScale: CGFloat
    /// This atlas's texture dimensions (= `Self.atlasSize` in production;
    /// smaller in tests that exercise eviction at low cardinality).
    let atlasSize: SIMD2<UInt32>

    /// Internal record holding the public `AtlasEntry` plus the
    /// monotonic access counter that orders LRU eviction. Counter is
    /// bumped on insert AND on every cache-hit lookup.
    private struct Record {
        var entry: AtlasEntry
        var lastAccess: UInt64
    }

    private var entries: [GlyphKey: Record] = [:]
    private var shelfX: UInt32 = 0
    private var shelfY: UInt32 = 0
    private var shelfHeight: UInt32 = 0
    private let fontHash: UInt64

    /// Parallel state for the color emoji atlas. Same shelf-packed
    /// algorithm + LRU eviction as the gray atlas; independent storage
    /// so emoji cache pressure can't evict ASCII glyphs and vice versa.
    private var colorEntries: [GlyphKey: Record] = [:]
    private var colorShelfX: UInt32 = 0
    private var colorShelfY: UInt32 = 0
    private var colorShelfHeight: UInt32 = 0
    private var colorFreeRects: [FreeRect] = []
    private var colorBytesAllocated: UInt64 = 0

    /// Resolved-fallback-font cache, keyed by `scalar.value >> 8`
    /// (256-codepoint Unicode block). Coarse but cheap: all of Thai
    /// (U+0E00..U+0E7F) lives in one block, basic Latin in another,
    /// CJK Unified Ideographs (U+4E00..U+9FFF) span 82 blocks but
    /// each is consistent — every CJK cell after the first within a
    /// block is a cache hit. Per-scalar caching would tighten the
    /// hit ratio for adversarial mixed-script traffic; profile if
    /// the resolver shows up in a flame graph (M2+).
    private var fontCacheByBlock: [UInt32: CTFont] = [:]

    /// FNV-1a hashes of resolved fallback fonts, memoized per
    /// `CTFont` instance identity. Keeps `entry(for:)` from rerunning
    /// `Self.hash(font:)` (PostScript-name UTF-8 walk + size mix) on
    /// every CJK/Thai/emoji cell once the block-cache is warm.
    private var fontHashByIdentity: [ObjectIdentifier: UInt64] = [:]

    /// Monotonic access counter — incremented on every `entry(for:)`
    /// call (both insert + cache hit). Wraps at `UInt64.max` (~6e8 years
    /// at 1 GHz access rate; ignore the wrap).
    private var accessCounter: UInt64 = 0

    /// Free rects produced by LRU eviction. First-fit allocator scans
    /// this list before falling back to shelf advance. Simple any-fit
    /// is intentional: shelf-packed allocations are uniform-cell-sized
    /// in practice (one CoreText glyph per cell), so a smarter
    /// allocator buys nothing at this scale.
    private struct FreeRect {
        let originPx: SIMD2<UInt32>
        let sizePx: SIMD2<UInt32>
    }
    private var freeRects: [FreeRect] = []

    /// Pinned regions that LRU eviction MUST NOT recycle. Currently
    /// holds the (0, 0) blank-slot reservation (see init).
    private struct PinnedRegion {
        let originPx: SIMD2<UInt32>
        let sizePx: SIMD2<UInt32>
    }
    private var pinnedRegions: [PinnedRegion] = []

    /// Total bytes currently allocated to live atlas entries (excludes
    /// pinned regions and free-listed rects). Asserted ≤ `maxBytes` on
    /// every allocation per the 4.2 acceptance gate.
    private var bytesAllocated: UInt64 = 0

    /// Bytes-per-pixel of the underlying texture. r8Unorm = 1.
    private static let bytesPerPixel: UInt64 = 1

    convenience init(
        device: MTLDevice, font: CTFont, contentsScale: CGFloat
    ) throws {
        try self.init(
            device: device, font: font, contentsScale: contentsScale,
            atlasSize: GlyphAtlas.atlasSize,
            colorAtlasSize: GlyphAtlas.defaultColorAtlasSize)
    }

    /// Designated initializer. `atlasSize` is parameterized so unit
    /// tests can stand up a small atlas and force eviction in a handful
    /// of inserts; production callers use the convenience init which
    /// pins `atlasSize = Self.atlasSize`.
    init(
        device: MTLDevice, font: CTFont, contentsScale: CGFloat,
        atlasSize: SIMD2<UInt32>,
        colorAtlasSize: SIMD2<UInt32> = GlyphAtlas.defaultColorAtlasSize
    ) throws {
        self.device = device
        self.font = font
        self.contentsScale = contentsScale
        self.atlasSize = atlasSize
        self.colorAtlasSize = colorAtlasSize
        self.fontHash = GlyphAtlas.hash(font: font)
        let pointSize = CTFontGetSize(font)
        let cellPt = GlyphAtlas.cellSize(for: font)
        self.cellSizePt = cellPt
        self.cellSizePx = SIMD2(
            UInt32(ceil(cellPt.width * contentsScale)),
            UInt32(ceil(cellPt.height * contentsScale)))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: Int(atlasSize.x),
            height: Int(atlasSize.y),
            mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: descriptor) else {
            throw AtlasError.textureAllocFailed
        }
        tex.label = "GlyphAtlas (gray, \(atlasSize.x)×\(atlasSize.y))"
        self.texture = tex

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Int(colorAtlasSize.x),
            height: Int(colorAtlasSize.y),
            mipmapped: false)
        colorDescriptor.storageMode = .private
        colorDescriptor.usage = [.shaderRead]
        guard let colorTex = device.makeTexture(descriptor: colorDescriptor)
        else {
            throw AtlasError.textureAllocFailed
        }
        colorTex.label =
            "GlyphAtlas (color, \(colorAtlasSize.x)×\(colorAtlasSize.y))"
        self.colorTexture = colorTex

        pinBlankSlot()

        _ = pointSize  // kept for future logging; silences unused-let
    }

    enum AtlasError: Error {
        case textureAllocFailed
        case rasterizationFailed
        case glyphMissing(Unicode.Scalar)
        case atlasFull(needed: SIMD2<UInt32>)
        /// A single allocation request would push live byte usage past
        /// `maxBytes`. Defensive — unreachable at the production
        /// 512² shelf but covered by tests so the contract sticks once
        /// we migrate to MTLHeap.
        case bytesCeilingExceeded(needed: UInt64, ceiling: UInt64)
    }

    /// Look up a glyph; rasterizing + uploading on cache miss. The
    /// upload is encoded onto `commandQueue` synchronously and waits
    /// for completion before returning, so the caller can use the
    /// entry on the very next frame's encode.
    ///
    /// Bumps the LRU access counter on both hit and insert paths, so
    /// recently-touched glyphs survive eviction pressure.
    func entry(
        for scalar: Unicode.Scalar,
        commandQueue: MTLCommandQueue
    ) throws -> AtlasEntry {
        // Procedural intercept: U+2500..U+257F (box drawing) and
        // U+2580..U+259F (block elements) bypass the font cascade.
        // Most monospace fonts paint these glyphs at extents narrower
        // than the cell advance, so adjacent rules visibly disconnect
        // (the dashed `─` defect). `BoxDrawing.rasterize` produces
        // coverage at the exact cell metric, guaranteeing pixel-
        // perfect joining across cell boundaries. The procedural
        // entries cache in the atlas like font glyphs — keyed by a
        // sentinel fontHash so they don't collide with primary-font
        // entries; the scalar value doubles as the glyphId so the
        // 160-codepoint range each gets its own atlas slot.
        if BoxDrawing.handles(scalar) {
            let key = GlyphKey(
                fontHash: Self.boxDrawingFontHash,
                glyphId: scalar.value,
                pxSize: 0,
                contentsScale: UInt8(contentsScale))

            accessCounter &+= 1
            if var cached = entries[key] {
                cached.lastAccess = accessCounter
                entries[key] = cached
                return cached.entry
            }

            let widthPx = Int(cellSizePx.x)
            let heightPx = Int(cellSizePx.y)
            guard
                let bytes = BoxDrawing.rasterize(
                    scalar: scalar,
                    widthPx: widthPx,
                    heightPx: heightPx)
            else {
                throw AtlasError.rasterizationFailed
            }
            let raster = RasterizedGlyph(
                bitmap: bytes,
                widthPx: widthPx,
                heightPx: heightPx,
                bearingPx: SIMD2(0, 0))
            let entry = try place(raster: raster, queue: commandQueue)
            entries[key] = Record(entry: entry, lastAccess: accessCounter)
            return entry
        }

        let (glyphId, resolvedFont) = try resolveGlyph(for: scalar)

        // A-emoji-4 routing: color emoji (AppleColorEmoji) goes through
        // the RGBA color atlas. Returns AtlasEntry with atlasIndex=1
        // so the renderer's grid pipeline writes selector=1 for the
        // cell and the shader samples colorAtlas instead of grayAtlas.
        if Self.isColorFont(resolvedFont) {
            let resolvedFontHash = cachedFontHash(for: resolvedFont)
            let key = GlyphKey(
                fontHash: resolvedFontHash,
                glyphId: UInt32(glyphId),
                pxSize: UInt16(
                    round(min(
                        CTFontGetSize(resolvedFont) * 100,
                        Double(UInt16.max)))),
                contentsScale: UInt8(contentsScale))
            accessCounter &+= 1
            if var cached = colorEntries[key] {
                cached.lastAccess = accessCounter
                colorEntries[key] = cached
                return cached.entry
            }
            let raster = try rasterizeColor(
                glyphId: glyphId, font: resolvedFont)
            let entry = try placeColor(
                raster: raster, queue: commandQueue)
            colorEntries[key] = Record(
                entry: entry, lastAccess: accessCounter)
            return entry
        }

        let resolvedFontHash =
            (resolvedFont === self.font)
            ? fontHash
            : cachedFontHash(for: resolvedFont)
        let key = GlyphKey(
            fontHash: resolvedFontHash,
            glyphId: UInt32(glyphId),
            pxSize: UInt16(round(CTFontGetSize(resolvedFont) * 100)),
            contentsScale: UInt8(contentsScale))

        accessCounter &+= 1
        if var cached = entries[key] {
            cached.lastAccess = accessCounter
            entries[key] = cached
            return cached.entry
        }

        let raster = try rasterize(glyphId: glyphId, font: resolvedFont)
        let entry = try place(raster: raster, queue: commandQueue)
        entries[key] = Record(entry: entry, lastAccess: accessCounter)
        return entry
    }

    /// Atlas entry for a multi-codepoint grapheme cluster (Thai base +
    /// tone mark, Devanagari + matra, Hindi conjuncts, Hangul jamo,
    /// emoji ZWJ sequences). The fast `entry(for: Unicode.Scalar)` path
    /// keys on a single scalar — it can't represent combining marks,
    /// which drop silently and produce visually broken Thai/Hindi.
    ///
    /// This path rasterizes the full string via `CTLine` so CoreText
    /// applies its shaping (mark positioning, ligatures). The result
    /// caches keyed by the cluster's UTF-8 bytes; subsequent renders
    /// of the same cluster hit the cache.
    ///
    /// Returned `AtlasEntry` is stored at the cell's grid slot; the
    /// renderer samples it identically to single-glyph entries.
    func entry(
        forCluster cluster: String,
        cellSpan: UInt8 = 1,
        commandQueue: MTLCommandQueue
    ) throws -> AtlasEntry {
        // Hash the cluster's UTF-8 bytes into the GlyphKey. FNV-1a is
        // cheap, collisions on real-world clusters are vanishingly
        // unlikely, and the same hash function backs the font-hash
        // path so the key shape stays uniform.
        //
        // cellSpan participates in the cache key: a cluster rasterized
        // at span=2 occupies a wider bitmap than the same cluster at
        // span=1 and the renderer would sample the wrong UV box if we
        // returned a shared slot. In practice the same string always
        // resolves to the same span, but keying defensively means
        // future logic that switches span mid-frame (e.g. cell-width
        // mutation) doesn't smear glyphs. The span byte rides in the
        // low bits of the `contentsScale` field — pre-coalescer all
        // existing callers pass cellSpan=1 so the key shape is
        // bit-identical to v0.1.6 (ADR-19 + spec/cross-cell-shaping.md).
        let span = max(UInt8(1), cellSpan)
        let clusterBytes = Array(cluster.utf8)
        let clusterHash = Self.fnv1a64(bytes: clusterBytes)
        let key = GlyphKey(
            fontHash: Self.clusterFontHash,
            glyphId: UInt32(clusterHash & 0xFFFF_FFFF),
            pxSize: UInt16(clusterHash >> 32 & 0xFFFF),
            contentsScale: (UInt8(contentsScale) << 4) | (span & 0x0F))

        // A-emoji-4 routing: emoji ZWJ + flag-sequence clusters resolve
        // to AppleColorEmoji which only rasterizes into RGBA. Route
        // through the color atlas — entry carries atlasIndex=1.
        let coveringFont = clusterCoveringFont(for: cluster)
        if Self.isColorFont(coveringFont) {
            accessCounter &+= 1
            if var cached = colorEntries[key] {
                cached.lastAccess = accessCounter
                colorEntries[key] = cached
                return cached.entry
            }
            let raster = try rasterizeColorCluster(
                cluster: cluster, coveringFont: coveringFont,
                cellSpan: span)
            var entry = try placeColor(
                raster: raster, queue: commandQueue)
            entry.cellSpan = span
            colorEntries[key] = Record(
                entry: entry, lastAccess: accessCounter)
            return entry
        }

        accessCounter &+= 1
        if var cached = entries[key] {
            cached.lastAccess = accessCounter
            entries[key] = cached
            return cached.entry
        }

        let raster = try rasterizeCluster(
            cluster: cluster, coveringFont: coveringFont,
            cellSpan: span)
        var entry = try place(raster: raster, queue: commandQueue)
        entry.cellSpan = span
        entries[key] = Record(entry: entry, lastAccess: accessCounter)
        return entry
    }

    /// Sentinel `fontHash` distinguishing cluster entries from single-
    /// glyph entries; like `boxDrawingFontHash` it's unreachable from
    /// the FNV-1a font-name hash.
    static let clusterFontHash: UInt64 = 0xC1_C1_C1_C1_C1_C1_C1_C1

    private static func fnv1a64(bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            hash ^= UInt64(b)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Grayscale cluster path. Color emoji clusters go through
    /// `rasterizeColorCluster` instead — caller (`entry(forCluster:)`)
    /// dispatches based on `clusterCoveringFont` color-font check.
    ///
    /// `cellSpan` widens the rasterization slot to
    /// `cellSpan * cellW × cellH` so coalesced cross-cell clusters
    /// (Thai consonant + SARA AM, RI flag pairs) keep their full
    /// horizontal extent. CTLine is drawn at x=0 (left-aligned per
    /// ADR-19), matching iTerm2/Ghostty for Thai compositions.
    private func rasterizeCluster(
        cluster: String, coveringFont: CTFont, cellSpan: UInt8 = 1
    ) throws -> RasterizedGlyph {
        let span = max(1, Int(cellSpan))
        let widthPx = Int(cellSizePx.x) * span
        let heightPx = Int(cellSizePx.y)
        var bitmap = [UInt8](repeating: 0, count: widthPx * heightPx)

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
            ctx.setShouldSmoothFonts(false)
            ctx.setFillColor(gray: 1.0, alpha: 1.0)
            ctx.scaleBy(x: contentsScale, y: contentsScale)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: coveringFont,
                .foregroundColor: CGColor(gray: 1.0, alpha: 1.0),
            ]
            let attrString = NSAttributedString(
                string: cluster, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrString)
            let descent = CTFontGetDescent(coveringFont)
            ctx.textPosition = CGPoint(x: 0, y: descent)
            CTLineDraw(line, ctx)
            return true
        }
        guard success else { throw AtlasError.rasterizationFailed }

        return RasterizedGlyph(
            bitmap: bitmap,
            widthPx: widthPx,
            heightPx: heightPx,
            bearingPx: SIMD2(0, 0))
    }

    /// RGBA cluster path for emoji ZWJ + flag sequences. Same CTLine
    /// shaping as gray cluster path but renders into deviceRGB so
    /// AppleColorEmoji's bitmap glyphs come through with full color.
    /// Returns RasterizedColorGlyph for the color atlas placement.
    ///
    /// `cellSpan` widens the rasterization slot to
    /// `cellSpan * cellW × cellH` so coalesced flag pairs / ZWJ-spill
    /// clusters keep their full horizontal extent (ADR-19).
    private func rasterizeColorCluster(
        cluster: String, coveringFont: CTFont, cellSpan: UInt8 = 1
    ) throws -> RasterizedColorGlyph {
        let span = max(1, Int(cellSpan))
        let widthPx = Int(cellSizePx.x) * span
        let heightPx = Int(cellSizePx.y)
        let bytesPerRow = widthPx * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * heightPx)

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
            let attrs: [NSAttributedString.Key: Any] = [
                .font: coveringFont,
            ]
            let attrString = NSAttributedString(
                string: cluster, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrString)
            let descent = CTFontGetDescent(coveringFont)
            ctx.textPosition = CGPoint(x: 0, y: descent)
            CTLineDraw(line, ctx)
            return true
        }
        guard drew else { throw AtlasError.rasterizationFailed }

        return RasterizedColorGlyph(
            bytes: bytes,
            widthPx: widthPx,
            heightPx: heightPx,
            bearingPx: SIMD2(0, 0))
    }

    /// Resolve a font that covers the entire cluster string as a single
    /// shaping run. Counterpart to `resolveFont(for:)` but on the full
    /// cluster rather than one scalar — needed so CTLine doesn't split
    /// `[base, combining-mark]` into independent fallback runs that lose
    /// mark-to-base attachment. The per-cluster cost is one CFString
    /// bridge + one `CTFontCreateForStringWithLanguage` call; the
    /// cluster atlas entry caches the rasterized result so each unique
    /// cluster pays it exactly once.
    private func clusterCoveringFont(for cluster: String) -> CTFont {
        let cf = cluster as CFString
        let length = CFStringGetLength(cf)
        guard length > 0 else { return self.font }
        let range = CFRange(location: 0, length: length)
        return CTFontCreateForStringWithLanguage(self.font, cf, range, nil)
    }

    /// Sentinel `GlyphKey.fontHash` value used by procedurally-rendered
    /// box-drawing + block-element entries. The only requirement is
    /// that it can't collide with a real CTFont's FNV-1a hash output;
    /// a hash-from-scratch over any PostScript-name string (which
    /// always starts from the FNV offset basis and applies the
    /// multiplicative chain) won't synthesize this value by accident.
    /// See `Self.hash(font:)`.
    static let boxDrawingFontHash: UInt64 = 0xB0_DA_DA_B0_DA_DA_B0_DA

    private func cachedFontHash(for font: CTFont) -> UInt64 {
        let id = ObjectIdentifier(font)
        if let h = fontHashByIdentity[id] { return h }
        let h = Self.hash(font: font)
        fontHashByIdentity[id] = h
        return h
    }

    var entryCount: Int { entries.count }

    /// Number of pinned regions (e.g. the blank slot). Test-only
    /// hook for the pinned-survival regression test.
    var pinnedRegionCount: Int { pinnedRegions.count }

    /// Live byte usage of allocated glyph entries. Test-only hook for
    /// the 64 MiB ceiling regression test.
    var bytesAllocatedForTest: UInt64 { bytesAllocated }

    /// Test-only: pre-charge `bytesAllocated` so the next ceiling
    /// check fires deterministically without needing 64 MiB worth of
    /// real CoreText rasters. Production code never calls this.
    func _testPrechargeBytes(_ value: UInt64) {
        bytesAllocated = value
    }

    /// Test-only: run the ceiling guard in isolation. Mirrors the
    /// branch at the head of `place(...)`.
    func _testCheckBytesCeiling(widthPx: UInt32, heightPx: UInt32) throws {
        let bytes = UInt64(widthPx) * UInt64(heightPx) * Self.bytesPerPixel
        if bytesAllocated + bytes > Self.maxBytes {
            throw AtlasError.bytesCeilingExceeded(
                needed: bytesAllocated + bytes, ceiling: Self.maxBytes)
        }
    }

    /// Test-only: drive the allocator with synthetic (width, height)
    /// dimensions. Lets `testAtlasResetOnFragmentationCliff` ask for
    /// rects that real cell-sized rasters never produce, exercising
    /// the free-list fragmentation fallback. Does not upload bitmap
    /// bytes — caller is responsible for never sampling the returned
    /// region.
    func _testAllocateRegion(
        width: UInt32, height: UInt32, queue: MTLCommandQueue
    ) throws -> SIMD2<UInt32> {
        try allocateOrigin(width: width, height: height, queue: queue)
    }

    /// Test-only: rasterize a cluster string and return the raw
    /// grayscale bitmap (no atlas upload, no caching). Lets the
    /// Thai-combining-mark regression test sample pixels in the upper
    /// third of the cell to assert that marks actually render.
    func _testRasterizeClusterBitmap(
        _ cluster: String
    ) throws -> (bitmap: [UInt8], widthPx: Int, heightPx: Int) {
        let coveringFont = clusterCoveringFont(for: cluster)
        let raster = try rasterizeCluster(
            cluster: cluster, coveringFont: coveringFont)
        return (raster.bitmap, raster.widthPx, raster.heightPx)
    }

    /// Test-only: synthetic insert that wires a fake `AtlasEntry` into
    /// the entries map without rasterizing. Used to seed LRU-ordering
    /// tests deterministically.
    func _testInsertSynthetic(
        key: GlyphKey, entry: AtlasEntry
    ) {
        accessCounter &+= 1
        entries[key] = Record(entry: entry, lastAccess: accessCounter)
        bytesAllocated += UInt64(entry.sizePx.x) * UInt64(entry.sizePx.y) * Self.bytesPerPixel
    }

    /// Test-only: peek the LRU access counter for a key. Returns nil
    /// if the key isn't present.
    func _testAccessCounter(for key: GlyphKey) -> UInt64? {
        entries[key]?.lastAccess
    }

    /// Test-only: snapshot of currently-live entry origins, useful for
    /// asserting which entries survived eviction.
    func _testLiveEntryKeys() -> Set<GlyphKey> {
        Set(entries.keys)
    }

    /// Test-only: count of cached fallback fonts in the per-block
    /// resolver cache. Tests use this to verify two scalars in the
    /// same Unicode block hit a single resolver call.
    var _testFontCacheBlockCount: Int { fontCacheByBlock.count }

    /// Test-only: resolve a scalar to its `(glyphId, font)` pair via
    /// the same path `entry(for:)` uses. Tests use this to verify
    /// fallback fonts differ across scripts without building the
    /// GlyphKey by hand.
    func _testResolveGlyph(
        for scalar: Unicode.Scalar
    ) throws -> (CGGlyph, CTFont) {
        try resolveGlyph(for: scalar)
    }

    // MARK: - Cell-size derivation

    /// Cell metrics derived from the font: monospace advance for width,
    /// ascent + descent + leading for line height. Rounded up to whole
    /// points so the cell fits an integer pixel grid at 1× scale; the
    /// atlas allocator further multiplies by `contentsScale`.
    static func cellSize(for font: CTFont) -> CGSize {
        var advance = CGSize.zero
        var glyph: CGGlyph = 0
        let m: UniChar = UniChar(UnicodeScalar("M").value)
        var input = m
        if CTFontGetGlyphsForCharacters(font, &input, &glyph, 1) {
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        }
        let width = max(1.0, ceil(advance.width))
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let height = max(1.0, ceil(ascent + descent + leading))
        return CGSize(width: width, height: height)
    }

    /// Does `glyphId` in `font` resolve to a bitmap-color glyph (sbix
    /// table, e.g. Apple Color Emoji)? `CTFontDrawGlyphs` only emits
    /// pixels for sbix glyphs when the destination CGContext has an
    /// alpha channel; rasterizing them into a deviceGray context
    /// produces nothing. Checking the font's PostScript name covers
    /// the macOS-shipped color font without expensive per-glyph table
    /// introspection.
    static func isColorGlyph(font: CTFont, glyphId: CGGlyph) -> Bool {
        isColorFont(font)
    }

    /// Whether `font` is a bitmap-color font (sbix table). Currently
    /// recognizes Apple Color Emoji by PostScript name. Extend the
    /// match-list when shipping Noto Color Emoji or Twemoji binding.
    static func isColorFont(_ font: CTFont) -> Bool {
        let name =
            CTFontCopyPostScriptName(font) as String? ?? ""
        return name.lowercased().contains("applecoloremoji")
    }

    static func hash(font: CTFont) -> UInt64 {
        let name = CTFontCopyPostScriptName(font) as String
        let size = CTFontGetSize(font)
        var h: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a offset
        for byte in name.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0100_0000_01b3
        }
        let sizeBits = UInt64(bitPattern: Int64(size.bitPattern))
        h ^= sizeBits
        h = h &* 0x0100_0000_01b3
        return h
    }

    // MARK: - Glyph resolution + rasterization

    /// Resolve a scalar to its `(glyphId, font)` pair. Walks the
    /// fallback cascade only when the primary font lacks a glyph.
    /// Astral scalars (> U+FFFF) skip the BMP fast path and go
    /// straight to CoreText's per-string resolver, which handles
    /// surrogate-pair encoding internally.
    ///
    /// SPEC DEVIATION (pre-authorized): `spec/metal-renderer.md`
    /// §Font Fallback Cascade describes a static
    /// `kCTFontCascadeListAttribute` chain (Menlo → PingFang →
    /// Hiragino → Thonburi → AppleColorEmoji → LastResort). M1 task
    /// 4.3 in `spec/m1-task-breakdown.md` overrides that with the
    /// per-string `CTFontCreateForStringWithLanguage` call below —
    /// the brief is the source of truth for this implementation.
    /// Per-string resolution is language-aware (Han disambiguation)
    /// and avoids the static-chain failure mode where a font lower
    /// in the chain shadows a better match in a font higher up. The
    /// spec text should be reconciled post-merge to reflect the
    /// chosen approach. Cascade-list-attribute remains the right
    /// tool when we want a single shaping run to draw a mixed-script
    /// line via `CTLine` (M2+ shape-cache work).
    private func resolveGlyph(
        for scalar: Unicode.Scalar
    ) throws -> (CGGlyph, CTFont) {
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
    private func resolveFont(for scalar: Unicode.Scalar) -> CTFont {
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

    private struct RasterizedGlyph {
        let bitmap: [UInt8]
        let widthPx: Int
        let heightPx: Int
        let bearingPx: SIMD2<Int32>
    }

    private func rasterize(
        glyphId: CGGlyph, font: CTFont
    ) throws -> RasterizedGlyph {
        let widthPx = Int(cellSizePx.x)
        let heightPx = Int(cellSizePx.y)

        // Thai-and-friends fix: when the resolved fallback font draws
        // a glyph that extends above the primary cell's ascent (e.g.
        // SARA AM ำ's NIKHAHIT circle, MAI HAN-AKAT + tone stacks,
        // tall CJK), the cell-sized rasterization bitmap clips the
        // top — user-visible as "missing circle on ำ" or chopped tone
        // marks. Scale the fallback font down to fit. Glyph IDs are
        // stable across same-face size changes so the existing glyph
        // ID still resolves in the scaled copy.
        let cellAscentPt = CTFontGetAscent(self.font)
        var renderFont = font
        var bbox = CGRect.zero
        var localGlyph = glyphId
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &localGlyph, &bbox, 1)
        if bbox.maxY > cellAscentPt {
            let scale = cellAscentPt / bbox.maxY
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
    private func pinBlankSlot() {
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

    // MARK: - Shelf packer + LRU eviction + blit upload

    private func place(raster: RasterizedGlyph, queue: MTLCommandQueue) throws -> AtlasEntry {
        let w = UInt32(raster.widthPx)
        let h = UInt32(raster.heightPx)
        let bytes = UInt64(w) * UInt64(h) * Self.bytesPerPixel

        // Hard ceiling check — defensive at the production 512² shelf
        // (unreachable in practice) but contract-pinned for post-M1.
        if bytesAllocated + bytes > Self.maxBytes {
            throw AtlasError.bytesCeilingExceeded(
                needed: bytesAllocated + bytes, ceiling: Self.maxBytes)
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
    private func allocateOrigin(
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
        while !entries.isEmpty {
            evictOneLRU()
            if let origin = takeFromFreeList(width: w, height: h) {
                return origin
            }
        }
        // Free-list fragmentation cliff: every evictable entry has
        // been freed yet the request still won't fit. Reset wholesale
        // and try once more. A reset re-pins the blank slot.
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
    private func evictOneLRU() {
        guard
            let victim = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })
        else { return }
        let rect = victim.value.entry
        freeRects.append(
            FreeRect(originPx: rect.originPx, sizePx: rect.sizePx))
        let bytes = UInt64(rect.sizePx.x) * UInt64(rect.sizePx.y) * Self.bytesPerPixel
        bytesAllocated -= min(bytesAllocated, bytes)
        entries.removeValue(forKey: victim.key)
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
    private struct RasterizedColorGlyph {
        let bytes: [UInt8]  // RGBA premultipliedLast
        let widthPx: Int
        let heightPx: Int
        let bearingPx: SIMD2<Int32>
    }

    private func rasterizeColor(
        glyphId: CGGlyph, font: CTFont
    ) throws -> RasterizedColorGlyph {
        let widthPx = Int(cellSizePx.x)
        let heightPx = Int(cellSizePx.y)
        let bytesPerRow = widthPx * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * heightPx)

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
            let descent = CTFontGetDescent(font)
            var pos = CGPoint(x: 0, y: descent)
            var localGlyph = glyphId
            CTFontDrawGlyphs(font, &localGlyph, &pos, 1, ctx)
            return true
        }
        guard drew else { throw AtlasError.rasterizationFailed }

        var rectGlyph = glyphId
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(
            font, .horizontal, &rectGlyph, &rect, 1)
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
    private func placeColor(
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
        while !colorEntries.isEmpty {
            evictOneColorLRU()
            if let origin = takeFromColorFreeList(width: w, height: h) {
                return origin
            }
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
        where colorFreeRects[i].sizePx.x >= w && colorFreeRects[i].sizePx.y >= h
        {
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

    private func evictOneColorLRU() {
        guard
            let victim = colorEntries.min(by: {
                $0.value.lastAccess < $1.value.lastAccess
            })
        else { return }
        let entry = victim.value.entry
        colorEntries.removeValue(forKey: victim.key)
        colorFreeRects.append(
            FreeRect(originPx: entry.originPx, sizePx: entry.sizePx))
        let bytes =
            UInt64(entry.sizePx.x) * UInt64(entry.sizePx.y)
            * Self.colorBytesPerPixel
        colorBytesAllocated = colorBytesAllocated >= bytes
            ? colorBytesAllocated - bytes : 0
    }

    private func resetColorAtlas() {
        colorEntries.removeAll(keepingCapacity: true)
        colorFreeRects.removeAll(keepingCapacity: true)
        colorBytesAllocated = 0
        colorShelfX = 0
        colorShelfY = 0
        colorShelfHeight = 0
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
