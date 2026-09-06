// Atlas LRU eviction — algorithm ported from Alacritty's
// `alacritty/src/renderer/text/atlas.rs` (Apache-2.0). Original
// copyright Joe Wilm and contributors; see
// <https://github.com/alacritty/alacritty/blob/master/alacritty/src/renderer/text/atlas.rs>.
// The shelf-packing + LRU pattern is structural; the Swift
// implementation against Metal is original.
//
// The renderer's glyph atlas.
//
// Stage 1: shelf-packed bitmap atlas with LRU eviction (M1 task 4.2).
// Single grayscale `MTLTexture` (.r8Unorm, 512×512), shelf-packed,
// uploaded via a shared-storage staging buffer + `MTLBlitCommandEncoder`.
// CoreText rasterizes each glyph into a CPU
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
//
// The atlas is split along its MARKs across sibling files: glyph
// resolution + rasterization and the pinned blank slot in
// GlyphAtlas+Rasterization.swift, the shelf packer / LRU eviction /
// blit upload in GlyphAtlas+Packing.swift, the color-emoji atlas and
// its public test seam in GlyphAtlas+ColorAtlas.swift. What stays
// here: `AtlasEntry`, `GlyphKey`, the class declaration with every
// stored property, init, the cross-cell cluster path and the
// cell-size derivation.

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
/// spillover). See ADR-0003. Defaults to 1
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
    /// Production atlas dimensions in pixels. 2048 × 2048 × 1 B = 4 MiB.
    /// Bumped from 512² (which held only ~80 two-cell cells): dense
    /// scripts where almost every syllable is a distinct coalesced
    /// cluster — Thai (consonant + vowel/tone), Devanagari, etc. — blew
    /// past the old shelf in a single viewport, and the same-frame
    /// eviction guard then rendered the overflow blank (missing glyphs).
    /// 2048² holds ~1.3k two-cell clusters, comfortably more than one
    /// screen. Still far under the 64 MiB ceiling.
    static let atlasSize: SIMD2<UInt32> = SIMD2(2048, 2048)

    /// Color emoji atlas dimensions. 1024 × 1024 × 4 B = 4 MiB —
    /// compromise between the designed 2048² (16 MiB) and the gray
    /// atlas's 512² (1 MiB equivalent at RGBA). Holds ~hundreds of
    /// emoji cells before LRU eviction kicks in, which covers a
    /// typical Claude Code dogfood session without thrashing.
    static let defaultColorAtlasSize: SIMD2<UInt32> = SIMD2(1024, 1024)

    /// Bytes per pixel of the color atlas (rgba8Unorm = 4).
    static let colorBytesPerPixel: UInt64 = 4

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
    struct Record {
        var entry: AtlasEntry
        var lastAccess: UInt64
    }

    var entries: [GlyphKey: Record] = [:]
    var shelfX: UInt32 = 0
    var shelfY: UInt32 = 0
    var shelfHeight: UInt32 = 0
    private let fontHash: UInt64

    /// Parallel state for the color emoji atlas. Same shelf-packed
    /// algorithm + LRU eviction as the gray atlas; independent storage
    /// so emoji cache pressure can't evict ASCII glyphs and vice versa.
    var colorEntries: [GlyphKey: Record] = [:]
    var colorShelfX: UInt32 = 0
    var colorShelfY: UInt32 = 0
    var colorShelfHeight: UInt32 = 0
    var colorFreeRects: [FreeRect] = []
    var colorBytesAllocated: UInt64 = 0

    /// Resolved-fallback-font cache, keyed by `scalar.value >> 8`
    /// (256-codepoint Unicode block). Coarse but cheap: all of Thai
    /// (U+0E00..U+0E7F) lives in one block, basic Latin in another,
    /// CJK Unified Ideographs (U+4E00..U+9FFF) span 82 blocks but
    /// each is consistent — every CJK cell after the first within a
    /// block is a cache hit. Per-scalar caching would tighten the
    /// hit ratio for adversarial mixed-script traffic; profile if
    /// the resolver shows up in a flame graph (M2+).
    var fontCacheByBlock: [UInt32: CTFont] = [:]

    /// FNV-1a hashes of resolved fallback fonts, memoized per
    /// `CTFont` instance identity. Keeps `entry(for:)` from rerunning
    /// `Self.hash(font:)` (PostScript-name UTF-8 walk + size mix) on
    /// every CJK/Thai/emoji cell once the block-cache is warm.
    private var fontHashByIdentity: [ObjectIdentifier: UInt64] = [:]

    /// Cached bold / italic / bold-italic CTFont variants of the
    /// primary `font`. Built lazily on first lookup so users who never
    /// hit styled text pay nothing. The 4-entry max (including the
    /// plain key) keeps the dictionary trivially small.
    private var styledFonts: [UInt8: CTFont] = [:]

    /// Resolve a CTFont variant for the primary atlas font. Pass
    /// `(false, false)` for plain (returns `self.font` unchanged).
    /// Used by the renderer's `makeSlot` to pick a styled face for
    /// cells with the BOLD / ITALIC alacritty `Flags` bits set.
    func styledFont(bold: Bool, italic: Bool) -> CTFont {
        let key: UInt8 = (bold ? 1 : 0) | (italic ? 2 : 0)
        if key == 0 { return self.font }
        if let cached = styledFonts[key] { return cached }
        let resolved = FontSettings.applyTraits(
            to: self.font, bold: bold, italic: italic)
        styledFonts[key] = resolved
        return resolved
    }

    /// Monotonic access counter — incremented on every `entry(for:)`
    /// call (both insert + cache hit). Wraps at `UInt64.max` (~6e8 years
    /// at 1 GHz access rate; ignore the wrap).
    var accessCounter: UInt64 = 0

    /// Eviction floor: only entries with `lastAccess <= frameAccessFloor`
    /// may be evicted. `beginResolveBatch()` snapshots `accessCounter`
    /// here at the start of each frame's slot resolution, pinning glyphs
    /// placed THIS batch — evicting one would free a rect a CellSlot
    /// resolved earlier this frame still points at, aliasing it to the
    /// glyph that reuses the rect (the mid-screen CJK/Thai garble + the
    /// per-frame full-repaint thrash when the working set exceeds the
    /// atlas). Defaults to `.max` (plain LRU) for out-of-band callers.
    var frameAccessFloor: UInt64 = .max

    /// Pin all currently-resolved glyphs against eviction for the duration
    /// of one frame's slot-resolution batch. The renderer calls this
    /// before resolving a frame's cells; the gray and color atlases share
    /// the floor. See `evictOneLRU` / `frameAccessFloor`.
    func beginResolveBatch() {
        frameAccessFloor = accessCounter
    }

    /// Free rects produced by LRU eviction. First-fit allocator scans
    /// this list before falling back to shelf advance. Simple any-fit
    /// is intentional: shelf-packed allocations are uniform-cell-sized
    /// in practice (one CoreText glyph per cell), so a smarter
    /// allocator buys nothing at this scale.
    struct FreeRect {
        let originPx: SIMD2<UInt32>
        let sizePx: SIMD2<UInt32>
    }
    var freeRects: [FreeRect] = []

    /// Pinned regions that LRU eviction MUST NOT recycle. Currently
    /// holds the (0, 0) blank-slot reservation (see init).
    struct PinnedRegion {
        let originPx: SIMD2<UInt32>
        let sizePx: SIMD2<UInt32>
    }
    var pinnedRegions: [PinnedRegion] = []

    /// Set by `evictOneLRU` / `resetAtlas` / `evictOneColorLRU`. The
    /// renderer reads this once per frame via `consumePendingEviction`
    /// and, when true, forces a full-viewport repaint via
    /// `take_full_frame_delta` so every cell's UV is re-resolved
    /// against the post-eviction atlas. Without this, cells whose
    /// glyphs got evicted continue to display the previous occupant
    /// of their UV slot — the user sees garbled (often Thai/CJK) text
    /// until they scroll, which forces a redraw. Regression report
    /// 2026-05-23: long sessions show garbled text mid-screen until
    /// any scroll/cell-touch event re-pins the cells.
    var pendingEviction: Bool = false

    /// Called by the renderer at the top of each draw tick. Returns
    /// true when an eviction or reset happened since the last call
    /// and resets the latch.
    func consumePendingEviction() -> Bool {
        let was = pendingEviction
        pendingEviction = false
        return was
    }

    /// Total bytes currently allocated to live atlas entries (excludes
    /// pinned regions and free-listed rects). Asserted ≤ `maxBytes` on
    /// every allocation per the 4.2 acceptance gate.
    var bytesAllocated: UInt64 = 0

    /// Bytes-per-pixel of the underlying texture. r8Unorm = 1.
    static let bytesPerPixel: UInt64 = 1

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

        // sRGB format (not plain .rgba8Unorm): AppleColorEmoji bitmaps are
        // rasterized in a deviceRGB (sRGB) context, so their bytes are
        // sRGB-encoded. The render pipeline blends in LINEAR space and the
        // drawable is `.bgra8Unorm_srgb` (linear→sRGB on write). Sampling
        // an sRGB texture hardware-decodes sRGB→linear, so the emoji enters
        // the linear composite correctly and round-trips once through the
        // framebuffer's encode. Plain .rgba8Unorm skipped the decode →
        // the values were sRGB-encoded twice → washed-out / pale emoji.
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
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
                    round(
                        min(
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

    /// Styled-glyph overload: rasterize `scalar` against `font`
    /// (typically a bold / italic / bold-italic variant of the atlas's
    /// primary CTFont) and cache the result keyed by the variant's own
    /// fontHash. Independent of the unstyled `entry(for:)` path so
    /// plain and styled cells coexist in the same atlas without
    /// collisions — bold `A` and plain `A` cache as separate slots.
    ///
    /// Fast path skips the procedural-box / color-emoji / cascade
    /// branches: bold/italic faces of monospace fonts cover the same
    /// codepoint set as their plain face for any character that
    /// actually carries styled text in practice (Latin, Cyrillic,
    /// Greek, CJK). If the variant lacks the glyph, fall back to the
    /// unstyled atlas entry — the user sees plain text instead of a
    /// missing-glyph block, matching common terminal behavior.
    func entry(
        for scalar: Unicode.Scalar,
        font: CTFont,
        commandQueue: MTLCommandQueue
    ) throws -> AtlasEntry {
        // BMP-only fast path. Astrals + multi-scalar clusters fall
        // through to the unstyled entry — styled astral text is rare
        // and the cluster path doesn't accept a font override yet.
        guard scalar.value <= 0xFFFF else {
            return try entry(for: scalar, commandQueue: commandQueue)
        }
        var ch = UniChar(scalar.value)
        var glyphId: CGGlyph = 0
        let ok = CTFontGetGlyphsForCharacters(font, &ch, &glyphId, 1)
        guard ok, glyphId != 0 else {
            return try entry(for: scalar, commandQueue: commandQueue)
        }

        let resolvedFontHash = cachedFontHash(for: font)
        let key = GlyphKey(
            fontHash: resolvedFontHash,
            glyphId: UInt32(glyphId),
            pxSize: UInt16(round(CTFontGetSize(font) * 100)),
            contentsScale: UInt8(contentsScale))

        accessCounter &+= 1
        if var cached = entries[key] {
            cached.lastAccess = accessCounter
            entries[key] = cached
            return cached.entry
        }

        let raster = try rasterize(glyphId: glyphId, font: font)
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
        // bit-identical to v0.1.6 (ADR-0003).
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

    /// Uniform downscale factor (≤ 1) so a shaped `CTLine`'s ink fits a
    /// `boxWidthPt × boxHeightPt` cell box when drawn at baseline
    /// `descent` (point space, pen origin x=0). Mirrors `fitScale` for
    /// the single-glyph paths but measures via `CTLineGetImageBounds`
    /// because a CTLine's per-run fonts can't be resized individually.
    ///
    /// `CTLineGetImageBounds` returns the ink rect relative to the line
    /// origin (pen at the baseline), so once the line is drawn at
    /// `textPosition = (0, descent)` the absolute ink Y spans
    /// `[descent + minY, descent + maxY]` and X spans `[minX, maxX]`.
    /// The box is `[0, boxWidthPt] × [0, boxHeightPt]`. Scaling about the
    /// origin keeps the left edge pinned at x=0 (ADR-0003). Returns 1.0
    /// when the line already fits.
    private static func clusterFitScale(
        line: CTLine,
        ctx: CGContext,
        descent: CGFloat,
        boxWidthPt: CGFloat,
        boxHeightPt: CGFloat
    ) -> CGFloat {
        let ink = CTLineGetImageBounds(line, ctx)
        guard !ink.isNull, ink.width > 0 || ink.height > 0 else {
            return 1.0
        }
        var scale: CGFloat = 1.0
        // Horizontal: ink right edge past the box. (minX is ~0 for
        // left-aligned terminal clusters; a negative minX would be folded
        // in by the width check below.)
        let inkRight = max(ink.maxX, ink.maxX - min(ink.minX, 0))
        if inkRight > boxWidthPt, inkRight > 0 {
            scale = min(scale, boxWidthPt / inkRight)
        }
        // Vertical: ink top above the box ceiling (descent + maxY) and
        // ink bottom below the floor (descent + minY < 0). The pivot is
        // the origin, so both ends scale toward it proportionally.
        let inkTop = descent + ink.maxY
        if inkTop > boxHeightPt, inkTop > 0 {
            scale = min(scale, boxHeightPt / inkTop)
        }
        let inkBottom = descent + ink.minY
        if inkBottom < 0, descent > 0 {
            // Need (descent + minY) * s >= 0 isn't achievable by scaling
            // about the origin when minY < -descent; instead bound the
            // total vertical extent to the box so nothing clips.
            let inkHeight = inkTop - inkBottom
            if inkHeight > boxHeightPt, inkHeight > 0 {
                scale = min(scale, boxHeightPt / inkHeight)
            }
        }
        return scale
    }

    /// Grayscale cluster path. Color emoji clusters go through
    /// `rasterizeColorCluster` instead — caller (`entry(forCluster:)`)
    /// dispatches based on `clusterCoveringFont` color-font check.
    ///
    /// `cellSpan` widens the rasterization slot to
    /// `cellSpan * cellW × cellH` so coalesced cross-cell clusters
    /// (Thai consonant + SARA AM, RI flag pairs) keep their full
    /// horizontal extent. CTLine is drawn at x=0 (left-aligned per
    /// ADR-0003), matching iTerm2/Ghostty for Thai compositions.
    private func rasterizeCluster(
        cluster: String, coveringFont: CTFont, cellSpan: UInt8 = 1
    ) throws -> RasterizedGlyph {
        let span = max(1, Int(cellSpan))
        let widthPx = Int(cellSizePx.x) * span
        let heightPx = Int(cellSizePx.y)
        var bitmap = [UInt8](repeating: 0, count: widthPx * heightPx)

        let boxWidthPt = CGFloat(widthPx) / contentsScale
        let boxHeightPt = CGFloat(heightPx) / contentsScale
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
            // Fit-to-box for clusters: a CTLine's per-run fonts can't be
            // resized individually, so measure the rendered ink and
            // scale the whole line uniformly about the origin (left edge
            // pinned at x=0 per ADR-0003) so tall/wide fallback clusters
            // don't clip. baseline=descent is in the same point space, so
            // it scales with the line. A cluster already inside the box
            // gets scale==1.0 → unchanged.
            let fit = Self.clusterFitScale(
                line: line, ctx: ctx, descent: descent,
                boxWidthPt: boxWidthPt, boxHeightPt: boxHeightPt)
            if fit < 1.0 { ctx.scaleBy(x: fit, y: fit) }
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
    /// clusters keep their full horizontal extent (ADR-0003).
    private func rasterizeColorCluster(
        cluster: String, coveringFont: CTFont, cellSpan: UInt8 = 1
    ) throws -> RasterizedColorGlyph {
        let span = max(1, Int(cellSpan))
        let widthPx = Int(cellSizePx.x) * span
        let heightPx = Int(cellSizePx.y)
        let bytesPerRow = widthPx * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * heightPx)

        let boxWidthPt = CGFloat(widthPx) / contentsScale
        let boxHeightPt = CGFloat(heightPx) / contentsScale
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
                .font: coveringFont
            ]
            let attrString = NSAttributedString(
                string: cluster, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrString)
            let descent = CTFontGetDescent(coveringFont)
            // Fit-to-box for color clusters (flag pairs, ZWJ-spill emoji)
            // — same uniform-scale-about-origin approach as the gray
            // cluster path; left edge pinned at x=0 (ADR-0003).
            let fit = Self.clusterFitScale(
                line: line, ctx: ctx, descent: descent,
                boxWidthPt: boxWidthPt, boxHeightPt: boxHeightPt)
            if fit < 1.0 { ctx.scaleBy(x: fit, y: fit) }
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
        // A LONE emoji-presentation-default scalar (⚡ U+26A1 — EAW=Wide,
        // so the engine reports width 2 and it arrives here as a 1-scalar
        // "cluster") must resolve to the color face, not via
        // CTFontCreateForStringWithLanguage which returns the monospace
        // primary font because it already covers the codepoint. The
        // `count == 1` guard is load-bearing: a multi-scalar `⚡︎` (VS15
        // text request) or `⚠️` (VS16 emoji request) keeps the standard
        // covering-font resolution, so both variation-selector overrides
        // stay correct.
        let scalars = Array(cluster.unicodeScalars)
        if scalars.count == 1, Self.prefersColorPresentation(scalars[0]) {
            return emojiPresentationFont
        }
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

    func cachedFontHash(for font: CTFont) -> UInt64 {
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

    /// Test-only: rasterize a single glyph for `scalar` resolved through
    /// the normal fallback cascade and return the raw grayscale bitmap
    /// (no atlas upload, no caching). Lets the fit-to-box regression
    /// test sample pixel coverage at the right/top edge to assert a
    /// wide/tall fallback glyph is shrunk to fit instead of clipped.
    func _testRasterizeGlyphBitmap(
        _ scalar: Unicode.Scalar
    ) throws -> (bitmap: [UInt8], widthPx: Int, heightPx: Int) {
        let (glyphId, resolvedFont) = try resolveGlyph(for: scalar)
        let raster = try rasterize(glyphId: glyphId, font: resolvedFont)
        return (raster.bitmap, raster.widthPx, raster.heightPx)
    }

    /// Test-only: bounding-rect (in points) of `scalar`'s resolved glyph
    /// in its fallback font, before any fit-to-box scaling. Lets the
    /// regression test confirm the glyph genuinely overflows the cell
    /// box (so the fit path is actually exercised, not a no-op).
    func _testGlyphBBoxAndCellPt(
        _ scalar: Unicode.Scalar
    ) throws -> (bbox: CGRect, cellWidthPt: CGFloat, cellHeightPt: CGFloat) {
        let (glyphId, resolvedFont) = try resolveGlyph(for: scalar)
        var localGlyph = glyphId
        var bbox = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(
            resolvedFont, .horizontal, &localGlyph, &bbox, 1)
        return (
            bbox,
            CGFloat(cellSizePx.x) / contentsScale,
            CGFloat(cellSizePx.y) / contentsScale
        )
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

    /// True iff the scalar's DEFAULT Unicode presentation is emoji
    /// (Emoji_Presentation=Yes — ⚡ U+26A1, ❗ U+2757, 👍). Such scalars
    /// must render in COLOR even when the monospace primary font happens
    /// to carry a monochrome glyph for them (Menlo covers ⚡, so the per-
    /// scalar cascade would otherwise keep ⚡ gray). Backed by the OS
    /// Unicode data — reliable on macOS 14: true for ⚡/❗/👍, false for
    /// the text-default ⚠ U+26A0 / ℹ U+2139 / ™, and false for ASCII
    /// digits and '#' (Emoji=Yes but Emoji_Presentation=No). Exactly the
    /// Emoji_Presentation property, so no hand-rolled table is needed.
    static func prefersColorPresentation(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmojiPresentation
    }

    /// Apple Color Emoji face at the atlas's point size. Lazily created
    /// once — the renderer rebuilds the whole atlas on any font-size
    /// change, so `self.font` (and thus this size) is fixed for the
    /// atlas's lifetime. Used to FORCE color for emoji-presentation-
    /// default scalars: `CTFontCreateForStringWithLanguage` is useless
    /// for these because it returns the primary font precisely BECAUSE
    /// that font already covers the codepoint, so the color face must be
    /// requested by name.
    lazy var emojiPresentationFont: CTFont =
        CTFontCreateWithName(
            "AppleColorEmoji" as CFString, CTFontGetSize(self.font), nil)

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
}
