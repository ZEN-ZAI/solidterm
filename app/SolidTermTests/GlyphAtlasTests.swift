// Implements spec/metal-renderer.md §Glyph atlas — observable contracts:
// rasterization populates the entry map, atlas rect is non-zero, multiple
// glyphs co-exist in the texture without crashing the blit upload, and
// (M1 task 4.2) LRU eviction recycles rects when the shelf overflows.

import CoreText
import Metal
import XCTest

@testable import SolidTerm

final class GlyphAtlasTests: XCTestCase {

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var atlas: GlyphAtlas!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 14, nil)
        atlas = try GlyphAtlas(device: device, font: font, contentsScale: 2.0)
    }

    override func tearDown() {
        atlas = nil
        queue = nil
        device = nil
    }

    func testCellSizeFromMenlo14() {
        // Menlo-Regular at 14 pt has a stable monospace advance and line
        // height across macOS releases. We don't assert exact values
        // (those vary subtly across CT versions) but bound them.
        let cellSize = GlyphAtlas.cellSize(for: atlas.font)
        XCTAssertGreaterThan(cellSize.width, 5.0)
        XCTAssertLessThan(cellSize.width, 20.0)
        XCTAssertGreaterThan(cellSize.height, 10.0)
        XCTAssertLessThan(cellSize.height, 30.0)
    }

    func testAtlasTextureWiredCorrectly() {
        XCTAssertEqual(atlas.texture.pixelFormat, .r8Unorm)
        XCTAssertEqual(atlas.texture.width, 512)
        XCTAssertEqual(atlas.texture.height, 512)
        XCTAssertEqual(atlas.texture.storageMode, .private)
    }

    func testRasterizeAsciiGlyphInsertsEntry() throws {
        XCTAssertEqual(atlas.entryCount, 0)
        let entry = try atlas.entry(for: Unicode.Scalar("A"), commandQueue: queue)
        XCTAssertEqual(atlas.entryCount, 1)
        XCTAssertGreaterThan(entry.sizePx.x, 0)
        XCTAssertGreaterThan(entry.sizePx.y, 0)
        // First glyph lands one cell-width + 1 px past the atlas origin:
        // position (0, 0) is reserved as the canonical "blank slot" so
        // cells with `slot.glyph == nil` (for which `GridPipeline.setRegion`
        // writes UV = (0, 0)) sample empty texels and render bg-only. The
        // +1 is the linear-filter guard: at the cell-right-edge UV the
        // filter taps texels (cellSize-1, cellSize) so a glyph at
        // x=cellSize would bleed into half of every blank cell.
        //
        // Post-4.2: the pinned-blank invariant is maintained by
        // `pinBlankSlot()`; the shelf cursor starts at `cellSizePx.x + 1`
        // so the first allocation lands at the same origin as before.
        XCTAssertEqual(entry.originPx, SIMD2(atlas.cellSizePx.x + 1, 0))
    }

    func testRasterizeCachesEntries() throws {
        let first = try atlas.entry(for: Unicode.Scalar("A"), commandQueue: queue)
        let second = try atlas.entry(for: Unicode.Scalar("A"), commandQueue: queue)
        XCTAssertEqual(atlas.entryCount, 1, "second lookup should hit the cache")
        XCTAssertEqual(first.originPx, second.originPx)
    }

    /// Emoji silhouette path (A-emoji-pre): a color-font glyph
    /// (Apple Color Emoji is bitmap-color, sbix table) used to draw
    /// nothing into a deviceGray context — the user saw black tofu.
    /// The fix routes color-font glyphs through a temporary RGBA
    /// context and copies the alpha channel into the r8 atlas, so
    /// at minimum the entry inserts cleanly and the atlas tracks it.
    /// Sampling pixel data requires a private-storage copy + blit
    /// which is overkill at this layer; the contract here is "no
    /// throw + entry present + rect non-zero".
    func testEmojiInsertsAtlasEntry() throws {
        XCTAssertEqual(atlas.entryCount, 0)
        XCTAssertEqual(atlas.colorEntryCount, 0)
        // 🎉 U+1F389 (PARTY POPPER) — single-codepoint color emoji,
        // 4 UTF-8 bytes. A-emoji-4 routes it through the color atlas.
        let scalar = Unicode.Scalar(0x1F389)!
        let entry = try atlas.entry(for: scalar, commandQueue: queue)
        XCTAssertEqual(entry.atlasIndex, 1, "emoji must land in color atlas")
        XCTAssertEqual(atlas.entryCount, 0, "gray atlas untouched")
        XCTAssertEqual(atlas.colorEntryCount, 1)
        XCTAssertGreaterThan(entry.sizePx.x, 0)
        XCTAssertGreaterThan(entry.sizePx.y, 0)
    }

    /// `isColorFont` correctly classifies AppleColorEmoji vs the
    /// primary monospace font. Pure helper test — no atlas roundtrip.
    func testIsColorFontClassifier() {
        let mono = CTFontCreateWithName("Menlo-Regular" as CFString, 14, nil)
        XCTAssertFalse(GlyphAtlas.isColorFont(mono))
        // Resolve the emoji font via the cluster fallback chain on a
        // known emoji scalar — exactly the path `rasterizeCluster`
        // would take.
        let emojiScalar = "\u{1F389}" as CFString
        let length = CFStringGetLength(emojiScalar)
        let range = CFRange(location: 0, length: length)
        let emoji = CTFontCreateForStringWithLanguage(
            mono, emojiScalar, range, nil)
        XCTAssertTrue(
            GlyphAtlas.isColorFont(emoji),
            "Apple Color Emoji must be detected as a color font")
    }

    /// A-emoji-1: color atlas is constructed as a sibling of the gray
    /// atlas, with rgba8Unorm pixel format and the default 1024² size.
    /// Standalone — doesn't require any routing change.
    func testColorAtlasTextureWiredCorrectly() {
        XCTAssertEqual(atlas.colorTexture.pixelFormat, .rgba8Unorm)
        XCTAssertEqual(
            atlas.colorTexture.width, Int(GlyphAtlas.defaultColorAtlasSize.x))
        XCTAssertEqual(
            atlas.colorTexture.height, Int(GlyphAtlas.defaultColorAtlasSize.y))
        XCTAssertEqual(atlas.colorTexture.storageMode, .private)
    }

    /// A-emoji-1: the standalone `colorEntry(for:commandQueue:)` API
    /// rasterizes an emoji into the color atlas and tracks it in the
    /// independent `colorEntries` map. The gray atlas's entry count
    /// is unaffected.
    func testColorEntryInsertsIntoColorAtlas() throws {
        XCTAssertEqual(atlas.entryCount, 0)
        XCTAssertEqual(atlas.colorEntryCount, 0)
        // 🎉 U+1F389 (PARTY POPPER) — resolves to Apple Color Emoji.
        let entry = try atlas.colorEntry(
            for: Unicode.Scalar(0x1F389)!, commandQueue: queue)
        XCTAssertEqual(
            entry.atlasIndex, 1,
            "color atlas entry must carry atlasIndex = 1")
        XCTAssertGreaterThan(entry.sizePx.x, 0)
        XCTAssertGreaterThan(entry.sizePx.y, 0)
        XCTAssertEqual(atlas.colorEntryCount, 1)
        XCTAssertEqual(
            atlas.entryCount, 0,
            "color insertions must NOT touch the gray atlas")
        XCTAssertGreaterThan(atlas.colorBytesAllocatedForTesting, 0)
    }

    /// A-emoji-1: second lookup of the same emoji scalar hits the
    /// color-atlas cache — no re-rasterization, same origin.
    func testColorEntryCachesEntries() throws {
        let first = try atlas.colorEntry(
            for: Unicode.Scalar(0x1F389)!, commandQueue: queue)
        let second = try atlas.colorEntry(
            for: Unicode.Scalar(0x1F389)!, commandQueue: queue)
        XCTAssertEqual(atlas.colorEntryCount, 1)
        XCTAssertEqual(first.originPx, second.originPx)
        XCTAssertEqual(first.atlasIndex, second.atlasIndex)
    }

    /// A-emoji-5: emoji ZWJ + flag-sequence clusters route through
    /// the color atlas via entry(forCluster:). Family emoji
    /// (👨‍👩‍👧 = U+1F468 ZWJ U+1F469 ZWJ U+1F467) is a 17-byte
    /// cluster but exercises the cluster path's covering-font dispatch.
    func testEmojiClusterRoutesToColorAtlas() throws {
        XCTAssertEqual(atlas.entryCount, 0)
        XCTAssertEqual(atlas.colorEntryCount, 0)
        let cluster = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let entry = try atlas.entry(
            forCluster: cluster, commandQueue: queue)
        XCTAssertEqual(
            entry.atlasIndex, 1,
            "emoji ZWJ cluster must land in color atlas")
        XCTAssertEqual(atlas.entryCount, 0, "gray atlas untouched")
        XCTAssertEqual(atlas.colorEntryCount, 1)
        XCTAssertGreaterThan(entry.sizePx.x, 0)
        XCTAssertGreaterThan(entry.sizePx.y, 0)
    }

    // MARK: - Emoji-presentation color routing (FIX-1)

    /// ⚡ U+26A1 is Emoji_Presentation=Yes but Menlo carries a monochrome
    /// glyph for it; without the presentation override it renders gray.
    /// The single-scalar path must force the Apple Color Emoji face →
    /// color atlas.
    func testEmojiPresentationScalarRoutesToColorAtlas() throws {
        XCTAssertEqual(atlas.colorEntryCount, 0)
        let entry = try atlas.entry(
            for: Unicode.Scalar(0x26A1)!, commandQueue: queue)
        XCTAssertEqual(
            entry.atlasIndex, 1,
            "⚡ (Emoji_Presentation=Yes) must land in the color atlas")
        XCTAssertEqual(atlas.colorEntryCount, 1)
        XCTAssertEqual(atlas.entryCount, 0, "gray atlas untouched")
    }

    /// ⚡ is EAW=Wide, so the engine reports width 2 and `makeSlot` routes
    /// it through `entry(forCluster:)` — the path it ACTUALLY takes.
    /// The lone-scalar covering-font override must keep it color.
    func testEmojiPresentationClusterRoutesToColorAtlas() throws {
        let entry = try atlas.entry(
            forCluster: "\u{26A1}", cellSpan: 2, commandQueue: queue)
        XCTAssertEqual(
            entry.atlasIndex, 1,
            "⚡ via the width-2 cluster path must land in the color atlas")
        XCTAssertEqual(atlas.colorEntryCount, 1)
    }

    /// Asserts resolution (not just routing): ⚡ resolves to an Apple
    /// Color Emoji face, not Menlo.
    func testEmojiPresentationResolvesToColorFont() throws {
        let (_, font) = try atlas._testResolveGlyph(for: Unicode.Scalar(0x26A1)!)
        let name = (CTFontCopyPostScriptName(font) as String).lowercased()
        XCTAssertTrue(
            name.contains("applecoloremoji"),
            "⚡ must resolve to AppleColorEmoji, got \(name)")
    }

    /// Text-default symbols (™ U+2122, ★ U+2605) are Emoji_Presentation=No
    /// and must STAY in the gray atlas — the override must not over-reach.
    func testTextDefaultSymbolsStayGray() throws {
        let tm = try atlas.entry(for: Unicode.Scalar(0x2122)!, commandQueue: queue)
        let star = try atlas.entry(for: Unicode.Scalar(0x2605)!, commandQueue: queue)
        XCTAssertEqual(tm.atlasIndex, 0, "™ must stay gray (text-default)")
        XCTAssertEqual(star.atlasIndex, 0, "★ must stay gray (text-default)")
    }

    /// ASCII '#' and '5' are Emoji=Yes but Emoji_Presentation=No (they
    /// only become emoji inside a keycap sequence) — must stay gray.
    func testAsciiEmojiCapableStaysGray() throws {
        let hash = try atlas.entry(for: Unicode.Scalar("#"), commandQueue: queue)
        let five = try atlas.entry(for: Unicode.Scalar("5"), commandQueue: queue)
        XCTAssertEqual(hash.atlasIndex, 0)
        XCTAssertEqual(five.atlasIndex, 0)
    }

    /// VS15 (U+FE0E) is an explicit TEXT request: ⚡︎ must stay gray. The
    /// `count == 1` guard in clusterCoveringFont keeps the multi-scalar
    /// sequence on the standard covering-font path, preserving the
    /// override.
    func testVS15ForcesTextPresentation() throws {
        let entry = try atlas.entry(
            forCluster: "\u{26A1}\u{FE0E}", cellSpan: 2, commandQueue: queue)
        XCTAssertEqual(
            entry.atlasIndex, 0,
            "⚡ + VS15 (text selector) must stay in the gray atlas")
    }

    /// Regression: VS16 text-default emoji (⚠️ U+26A0, ℹ️ U+2139) already
    /// resolve to AppleColorEmoji via their covering font — the FIX-1
    /// override must not disturb that (they are multi-scalar, so the
    /// lone-scalar branch never fires).
    func testVS16TextDefaultEmojiStayColor() throws {
        let warn = try atlas.entry(
            forCluster: "\u{26A0}\u{FE0F}", cellSpan: 2, commandQueue: queue)
        let info = try atlas.entry(
            forCluster: "\u{2139}\u{FE0F}", cellSpan: 2, commandQueue: queue)
        XCTAssertEqual(warn.atlasIndex, 1, "⚠️ must stay color")
        XCTAssertEqual(info.atlasIndex, 1, "ℹ️ must stay color")
    }

    /// A-emoji-5: Thai 3-mark clusters (consonant + upper vowel +
    /// tone) stay in the GRAY atlas — they're not color-font emoji.
    /// Regression pin for the dispatcher: emoji-vs-Thai routing
    /// must NOT flip on Thai clusters.
    func testThaiClusterStaysInGrayAtlas() throws {
        XCTAssertEqual(atlas.entryCount, 0)
        XCTAssertEqual(atlas.colorEntryCount, 0)
        // เพื่อน's second grapheme: พ + ื + ่ (consonant + upper
        // vowel + tone), 9 UTF-8 bytes, fits the 16-byte buffer.
        let cluster = "\u{0E1E}\u{0E37}\u{0E48}"
        let entry = try atlas.entry(
            forCluster: cluster, commandQueue: queue)
        XCTAssertEqual(
            entry.atlasIndex, 0,
            "Thai cluster must land in gray atlas")
        XCTAssertEqual(atlas.entryCount, 1)
        XCTAssertEqual(atlas.colorEntryCount, 0)
    }

    func testMultipleGlyphsPackOnShelf() throws {
        let scalars: [Unicode.Scalar] = ["A", "B", "C", "0", "1", "2", "3"]
        var lastX: UInt32 = 0
        for s in scalars {
            let entry = try atlas.entry(for: s, commandQueue: queue)
            // Shelf packer monotonically advances the X cursor along
            // a single row at the spike scale (cell width × 7 << 512).
            XCTAssertGreaterThanOrEqual(entry.originPx.x, lastX)
            lastX = entry.originPx.x + entry.sizePx.x
        }
        XCTAssertEqual(atlas.entryCount, scalars.count)
    }

    func testUVCoordinatesAreNormalized() throws {
        let entry = try atlas.entry(for: Unicode.Scalar("A"), commandQueue: queue)
        let origin = entry.uvOrigin(atlasSize: GlyphAtlas.atlasSize)
        let size = entry.uvSize(atlasSize: GlyphAtlas.atlasSize)
        XCTAssertGreaterThanOrEqual(origin.x, 0.0)
        XCTAssertGreaterThanOrEqual(origin.y, 0.0)
        XCTAssertLessThanOrEqual(origin.x + size.x, 1.0)
        XCTAssertLessThanOrEqual(origin.y + size.y, 1.0)
    }

    // MARK: - LRU eviction (M1 task 4.2)

    /// Build a small-size atlas that forces eviction in a handful of
    /// inserts. Production callers always use the convenience init.
    private func makeSmallAtlas(side: UInt32 = 100) throws -> GlyphAtlas {
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 14, nil)
        return try GlyphAtlas(
            device: device, font: font, contentsScale: 2.0,
            atlasSize: SIMD2(side, side))
    }

    /// Fill a small atlas to capacity by walking ASCII letters until
    /// the next insert would evict. Returns the keys in insertion
    /// order so tests can reason about LRU ordering.
    private func fillToCapacity(
        _ small: GlyphAtlas, scalars: [Unicode.Scalar]
    ) throws -> [GlyphKey] {
        var keys: [GlyphKey] = []
        for s in scalars {
            _ = try small.entry(for: s, commandQueue: queue)
            // Recompute the key the same way the atlas does. Tests use
            // BMP scalars only, so the resolution is straightforward.
            let glyphId = try resolveGlyphForTest(small.font, scalar: s)
            keys.append(
                GlyphKey(
                    fontHash: GlyphAtlas.hash(font: small.font),
                    glyphId: UInt32(glyphId),
                    pxSize: UInt16(round(CTFontGetSize(small.font) * 100)),
                    contentsScale: UInt8(small.contentsScale)))
        }
        return keys
    }

    private func resolveGlyphForTest(
        _ font: CTFont, scalar: Unicode.Scalar
    ) throws -> CGGlyph {
        var ch = UniChar(scalar.value)
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1) else {
            throw NSError(domain: "GlyphAtlasTests", code: -1)
        }
        return glyph
    }

    func testLRUEvictsLeastRecentlyUsedOnOverflow() throws {
        let small = try makeSmallAtlas(side: 100)

        // Walk the ASCII printable range until the next insert would
        // need to evict. We touch the FIRST inserted scalar after each
        // insert to bump its LRU rank — so when eviction kicks in, the
        // *second* scalar inserted should be the victim, not the first.
        let scalars: [Unicode.Scalar] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars)
        var inserted: [GlyphKey] = []
        for s in scalars {
            let entryCountBefore = small.entryCount
            _ = try small.entry(for: s, commandQueue: queue)
            let glyphId = try resolveGlyphForTest(small.font, scalar: s)
            let key = GlyphKey(
                fontHash: GlyphAtlas.hash(font: small.font),
                glyphId: UInt32(glyphId),
                pxSize: UInt16(round(CTFontGetSize(small.font) * 100)),
                contentsScale: UInt8(small.contentsScale))

            if small.entryCount <= entryCountBefore && !inserted.isEmpty {
                // Eviction happened (entryCount didn't grow). The first
                // entry was kept hot — assert it survived and an
                // earlier (non-first) entry was evicted.
                let live = small._testLiveEntryKeys()
                XCTAssertTrue(
                    live.contains(inserted[0]),
                    "first-inserted entry should survive — it was touched on every insert")
                // Find the earliest-inserted key that was evicted; it
                // must NOT be inserted[0].
                let evicted = inserted.first { !live.contains($0) }
                XCTAssertNotNil(evicted, "exactly one eviction should have fired")
                XCTAssertNotEqual(
                    evicted, inserted[0],
                    "LRU must evict an older non-touched entry, not the recently-touched first one")
                return
            }

            inserted.append(key)
            // Touch the first entry to keep it hottest.
            if !inserted.isEmpty {
                _ = try small.entry(
                    for: scalars[0], commandQueue: queue)
            }
        }
        XCTFail("expected eviction within \(scalars.count) inserts on a 100-px atlas")
    }

    func testEvictedRegionIsReusable() throws {
        let small = try makeSmallAtlas(side: 100)

        // Drive inserts until eviction fires once.
        let scalars: [Unicode.Scalar] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars)
        var sawEviction = false
        var liveBefore: Set<GlyphKey> = []
        for s in scalars {
            let countBefore = small.entryCount
            liveBefore = small._testLiveEntryKeys()
            _ = try small.entry(for: s, commandQueue: queue)
            if small.entryCount <= countBefore {
                sawEviction = true
                break
            }
        }
        XCTAssertTrue(sawEviction, "expected at least one eviction")

        // After eviction, the freed rect MUST be reusable. Force one
        // more insert (a fresh scalar) and check it succeeds — i.e.,
        // doesn't throw `atlasFull`. The new entry should land at the
        // freed rect's origin (any-fit free-list pop).
        let nextScalar = Unicode.Scalar("a")
        let entry = try small.entry(for: nextScalar, commandQueue: queue)
        XCTAssertGreaterThan(entry.sizePx.x, 0)
        // The new entry's origin should differ from any survivor's
        // origin (it filled a hole, not a new shelf slot, OR it
        // advanced the shelf — either way the test passes if no
        // throw fires).
        XCTAssertEqual(small._testLiveEntryKeys().isSubset(of: liveBefore.union([])), false)
    }

    func testPinnedBlankSlotSurvivesEviction() throws {
        let small = try makeSmallAtlas(side: 100)
        XCTAssertEqual(
            small.pinnedRegionCount, 1,
            "atlas must initialise with one pinned blank-slot region")

        // Drive enough inserts to trigger several evictions.
        let scalars: [Unicode.Scalar] = Array(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij".unicodeScalars)
        for s in scalars {
            _ = try small.entry(for: s, commandQueue: queue)
        }

        // Pin must persist — entries map MUST NOT contain a key whose
        // entry origin is (0, 0). Atlas reset (cliff fallback) also
        // re-pins the blank slot, so this holds across resets too.
        XCTAssertEqual(
            small.pinnedRegionCount, 1,
            "blank slot must remain pinned after eviction pressure")
        for (_, _) in small._testLiveEntryKeys().enumerated() {}  // no-op
        // Direct check: no live entry should claim origin (0, 0).
        // We re-derive this via the public AtlasEntry surface by
        // walking what we just inserted — any (0,0) entry would mean
        // the shelf packer trampled the pinned region.
        for s in scalars {
            // Cache hit — bumps LRU but the origin is what was stored
            // at insert time. Survivors only.
            let liveKeys = small._testLiveEntryKeys()
            let glyphId = try resolveGlyphForTest(small.font, scalar: s)
            let key = GlyphKey(
                fontHash: GlyphAtlas.hash(font: small.font),
                glyphId: UInt32(glyphId),
                pxSize: UInt16(round(CTFontGetSize(small.font) * 100)),
                contentsScale: UInt8(small.contentsScale))
            if liveKeys.contains(key) {
                let entry = try small.entry(for: s, commandQueue: queue)
                XCTAssertFalse(
                    entry.originPx.x == 0 && entry.originPx.y == 0,
                    "no live glyph entry may sit on the pinned (0,0) blank slot")
            }
        }
    }

    func testAtlasResetOnFragmentationCliff() throws {
        // Use a very small atlas so eviction triggers fast.
        let small = try makeSmallAtlas(side: 80)

        // Fill it.
        let scalars: [Unicode.Scalar] = Array("ABCDEFGHIJ".unicodeScalars)
        for s in scalars {
            _ = try small.entry(for: s, commandQueue: queue)
        }

        // Synthetic request: ask for a rect WIDER than any shelf can
        // hold but narrower than the atlas. The free-list (populated
        // by per-cell evictions) won't satisfy a wider-than-cell
        // request; shelves are exhausted; reset path triggers; fresh
        // shelf serves the request.
        //
        // We pick `width = atlasSize - blankWidth - 1` so the request
        // fits a freshly-reset shelf (after the pinned blank reserves
        // the leading cells) but won't fit any single freed cell rect.
        let blankWidth = small.cellSizePx.x + 1
        let cliffWidth = small.atlasSize.x - blankWidth - 1
        let cliffHeight = small.cellSizePx.y
        XCTAssertGreaterThan(
            cliffWidth, small.cellSizePx.x,
            "test setup: cliff width must exceed cell width to defeat free-list")

        let origin = try small._testAllocateRegion(
            width: cliffWidth, height: cliffHeight, queue: queue)

        // After a reset + fresh advance, the new region should sit at
        // the post-pin origin (blankWidth, 0). A non-reset path could
        // never have produced this since shelves were full.
        XCTAssertEqual(origin, SIMD2(blankWidth, 0))
        XCTAssertEqual(
            small.entryCount, 0,
            "reset must clear the entries map")
        XCTAssertEqual(
            small.pinnedRegionCount, 1,
            "reset must re-pin the blank slot")
    }

    func testBytesAllocatedTracking() throws {
        XCTAssertEqual(atlas.bytesAllocatedForTest, 0)
        let entry = try atlas.entry(for: Unicode.Scalar("A"), commandQueue: queue)
        let expected = UInt64(entry.sizePx.x) * UInt64(entry.sizePx.y)
        XCTAssertEqual(
            atlas.bytesAllocatedForTest, expected,
            "bytesAllocated must reflect the cell-rect of the inserted glyph")
    }

    // MARK: - Font fallback (M1 task 4.3)

    func testLatinUsesPrimaryFont() throws {
        // Sanity: ASCII still walks the primary-font fast path. The
        // entry's GlyphKey carries the *primary* font's hash — i.e.
        // `GlyphAtlas.hash(font: atlas.font)`. Verified indirectly:
        // the resolver returns the primary CTFont identity.
        let (_, font) = try atlas._testResolveGlyph(for: Unicode.Scalar("A"))
        XCTAssertTrue(
            font === atlas.font,
            "ASCII 'A' must resolve via the primary font (Menlo) fast path")
        // The block-resolver cache must NOT have been populated by the
        // primary fast path — that's the whole point of bypassing it.
        XCTAssertEqual(
            atlas._testFontCacheBlockCount, 0,
            "primary fast path must not pollute the fallback-font cache")
    }

    func testThaiResolvesViaFallback() throws {
        // U+0E01 THAI CHARACTER KO KAI. Menlo lacks Thai; CoreText
        // resolves to Thonburi (or whatever the system picks for Thai
        // — don't assert the exact name, that varies across macOS).
        let scalar = Unicode.Scalar(0x0E01)!
        let (_, font) = try atlas._testResolveGlyph(for: scalar)
        XCTAssertFalse(
            font === atlas.font,
            "Thai must resolve via a fallback font, not the primary")

        // Drive the full insert path; entry must rasterize cleanly
        // and live in the atlas.
        XCTAssertEqual(atlas.entryCount, 0)
        let entry = try atlas.entry(for: scalar, commandQueue: queue)
        XCTAssertEqual(atlas.entryCount, 1)
        XCTAssertGreaterThan(entry.sizePx.x, 0)
        XCTAssertGreaterThan(entry.sizePx.y, 0)
    }

    func testCJKResolvesViaFallback() throws {
        // U+4E2D 中 — basic CJK Unified Ideograph. Menlo lacks Han;
        // CoreText resolves to PingFang/Hiragino/etc.
        let scalar = Unicode.Scalar(0x4E2D)!
        let (_, font) = try atlas._testResolveGlyph(for: scalar)
        XCTAssertFalse(
            font === atlas.font,
            "CJK must resolve via a fallback font, not the primary")

        let entry = try atlas.entry(for: scalar, commandQueue: queue)
        XCTAssertEqual(atlas.entryCount, 1)
        XCTAssertGreaterThan(entry.sizePx.x, 0)
    }

    func testThaiAndCJKResolveToDistinctFallbacks() throws {
        // Different scripts → CoreText picks different physical
        // fonts. Compare via FNV-1a hash of the resolved CTFonts so
        // we don't rely on `===` (CoreText may return distinct
        // CTFont instances backed by the same descriptor across calls).
        let (_, thaiFont) = try atlas._testResolveGlyph(
            for: Unicode.Scalar(0x0E01)!)
        let (_, cjkFont) = try atlas._testResolveGlyph(
            for: Unicode.Scalar(0x4E2D)!)
        XCTAssertNotEqual(
            GlyphAtlas.hash(font: thaiFont),
            GlyphAtlas.hash(font: cjkFont),
            "Thai and CJK must resolve to physically different fallback fonts")
    }

    func testEmojiResolvesViaFallback() throws {
        // U+1F600 GRINNING FACE — astral. Apple Color Emoji
        // resolves; rasterization renders to grayscale tofu /
        // silhouette in our r8Unorm atlas (full-color emoji needs
        // the dual-atlas migration tracked in tech-debt.md). The
        // atomic 4.3 acceptance is "no throw, an entry lands" — not
        // pixel-correctness for the color glyph.
        let scalar = Unicode.Scalar(0x1F600)!
        XCTAssertEqual(atlas.entryCount, 0)
        XCTAssertEqual(atlas.colorEntryCount, 0)
        let entry = try atlas.entry(for: scalar, commandQueue: queue)
        // A-emoji-4: emoji routes to color atlas.
        XCTAssertEqual(entry.atlasIndex, 1)
        XCTAssertEqual(atlas.entryCount, 0)
        XCTAssertEqual(atlas.colorEntryCount, 1)
        XCTAssertGreaterThan(entry.sizePx.x, 0)
        XCTAssertGreaterThan(entry.sizePx.y, 0)
    }

    func testFontCacheReusesAcrossScalarsInSameBlock() throws {
        // 中 (U+4E2D) and 国 (U+56FD) are both CJK Unified
        // Ideographs but live in different 256-cp blocks
        // (0x4E and 0x56). 中 (U+4E2D) and 久 (U+4E45) are in the
        // same block 0x4E — so the second call must hit the cache.
        let blockBefore = atlas._testFontCacheBlockCount
        _ = try atlas.entry(
            for: Unicode.Scalar(0x4E2D)!, commandQueue: queue)
        let blockAfterFirst = atlas._testFontCacheBlockCount
        XCTAssertEqual(
            blockAfterFirst, blockBefore + 1,
            "first CJK insert must populate one block-cache entry")

        _ = try atlas.entry(
            for: Unicode.Scalar(0x4E45)!, commandQueue: queue)
        XCTAssertEqual(
            atlas._testFontCacheBlockCount, blockAfterFirst,
            "second insert in same Unicode block must hit the resolver cache")
    }

    func testMultiFontGlyphsCoexistInAtlas() throws {
        // Insert Latin, Thai, CJK (gray atlas) + Emoji (color atlas).
        // A-emoji-4: emoji now routes to the color atlas; gray atlas
        // holds the first three, color atlas holds the fourth. All
        // four must round-trip via cache hits on a second lookup.
        let grayScalars: [Unicode.Scalar] = [
            Unicode.Scalar("A"),
            Unicode.Scalar(0x0E01)!,  // Thai ก
            Unicode.Scalar(0x4E2D)!,  // CJK 中
        ]
        let emojiScalar = Unicode.Scalar(0x1F600)!  // 😀

        var firstGrayOrigins: [SIMD2<UInt32>] = []
        for s in grayScalars {
            let e = try atlas.entry(for: s, commandQueue: queue)
            XCTAssertEqual(e.atlasIndex, 0)
            firstGrayOrigins.append(e.originPx)
        }
        let firstEmoji = try atlas.entry(
            for: emojiScalar, commandQueue: queue)
        XCTAssertEqual(firstEmoji.atlasIndex, 1)

        XCTAssertEqual(atlas.entryCount, 3)
        XCTAssertEqual(atlas.colorEntryCount, 1)

        // Cache hit pass — same origins, no new entries.
        for (i, s) in grayScalars.enumerated() {
            let e = try atlas.entry(for: s, commandQueue: queue)
            XCTAssertEqual(e.originPx, firstGrayOrigins[i])
        }
        let secondEmoji = try atlas.entry(
            for: emojiScalar, commandQueue: queue)
        XCTAssertEqual(secondEmoji.originPx, firstEmoji.originPx)

        XCTAssertEqual(atlas.entryCount, 3)
        XCTAssertEqual(atlas.colorEntryCount, 1)
    }

    /// Thai upper-vowel combining mark must produce non-zero pixel
    /// coverage in the upper region of the rasterized cluster bitmap.
    ///
    /// Regression for the f737032 follow-up defect: the cluster CTLine
    /// path used `self.font` (e.g. Menlo, no Thai coverage) for the
    /// attributed string, so CTLine's per-run cascade resolved the
    /// base consonant and the combining mark independently — the mark
    /// ended up in a font that lacked attachment data for the chosen
    /// base font and rendered as `.notdef` (effectively invisible for
    /// zero-advance marks). User-visible: "คืออะไร" → "คออะไร".
    ///
    /// Test: rasterize "คื" (ค U+0E04 + ื U+0E37) and "ค" alone, sum
    /// alpha in the bitmap's upper third. The atlas's CGContext is
    /// configured to write the row-major *top-down* layout Metal
    /// samples (see `rasterize`'s comment on the deliberate scale that
    /// flips into top-down memory), so row 0 = visually top of cell
    /// and the upper-vowel ink lands in the FIRST third of rows. The
    /// cluster MUST have meaningfully more coverage in that band than
    /// the bare base consonant. A tolerance of >50% more coverage
    /// gives clear signal without being brittle to anti-aliasing
    /// variance across CT versions.
    func testThaiUpperMarkProducesPixelCoverage() throws {
        // Use the production default font (JetBrains Mono) rather than
        // the test's setUp Menlo. JetBrains Mono lacks Thai coverage so
        // CTLine MUST cascade — which is exactly the failure mode this
        // test pins. Menlo's own cascade for "คื" happens to handle
        // marks without the fix, so testing on Menlo would silently
        // pass even on the broken code path. Use the raw CT API rather
        // than `FontSettings.makeCTFont` to keep the test off the
        // `@MainActor` global state.
        let jbm = CTFontCreateWithName(
            "JetBrainsMono-Regular" as CFString, 14, nil)
        let jbmAtlas = try GlyphAtlas(
            device: device, font: jbm, contentsScale: 2.0)
        // ค alone (no combining mark) — baseline coverage in the cell.
        let baseOnly = try jbmAtlas._testRasterizeClusterBitmap("ค")
        // ค + ื (combining upper vowel) — must add pixels above the
        // consonant. The renderer routes this through the cluster
        // path because `unicodeScalars.count > 1`.
        let cluster = try jbmAtlas._testRasterizeClusterBitmap("คื")

        XCTAssertEqual(baseOnly.widthPx, cluster.widthPx)
        XCTAssertEqual(baseOnly.heightPx, cluster.heightPx)
        let widthPx = cluster.widthPx
        let heightPx = cluster.heightPx

        // Row 0 = visually top of cell (top-down memory layout). Thai
        // upper vowel sits above the cap line — sample the top third.
        let upperRowsEnd = heightPx / 3
        func sumCoverage(_ bytes: [UInt8]) -> Int {
            var total = 0
            for row in 0..<upperRowsEnd {
                let rowBase = row * widthPx
                for col in 0..<widthPx {
                    total += Int(bytes[rowBase + col])
                }
            }
            return total
        }
        let baseUpper = sumCoverage(baseOnly.bitmap)
        let clusterUpper = sumCoverage(cluster.bitmap)

        // The combining-mark glyph must put real ink in the upper
        // third. A naive lower bound (>0) would pass even on a stray
        // antialiasing tap from the consonant's top edge — require a
        // substantial delta so the assertion catches the defect (where
        // the mark vanishes entirely and clusterUpper ≈ baseUpper).
        // The +1000 floor handles the edge case where baseUpper is 0
        // (no ascender ink for some fonts/scripts).
        XCTAssertGreaterThan(
            clusterUpper, baseUpper + (baseUpper / 2) + 1000,
            "Thai cluster 'คื' must put substantially more coverage "
                + "in the upper third than base 'ค' alone "
                + "(cluster=\(clusterUpper), base=\(baseUpper))")
    }

    func testBytesAllocatedTrue64MiBCeiling() throws {
        // Pre-charge close to the ceiling, then ask for a rect whose
        // bytes would push us past 64 MiB. The ceiling guard must
        // throw `bytesCeilingExceeded`.
        let ceiling = GlyphAtlas.maxBytes
        atlas._testPrechargeBytes(ceiling - 100)
        XCTAssertThrowsError(
            try atlas._testCheckBytesCeiling(widthPx: 200, heightPx: 1)
        ) { error in
            guard case GlyphAtlas.AtlasError.bytesCeilingExceeded(let needed, let cap) = error
            else {
                XCTFail("expected bytesCeilingExceeded, got \(error)")
                return
            }
            XCTAssertGreaterThan(needed, cap)
            XCTAssertEqual(cap, GlyphAtlas.maxBytes)
        }
        // Just under the ceiling — must NOT throw.
        atlas._testPrechargeBytes(ceiling - 100)
        XCTAssertNoThrow(
            try atlas._testCheckBytesCeiling(widthPx: 50, heightPx: 1))
    }

    // MARK: - cellSpan (ADR-19 atomic 2)

    /// A coalesced cross-cell cluster rasterizes into a slot sized
    /// `cellSpan * cellW × cellH`. Thai consonant + SARA AM stays in
    /// the gray atlas; the bitmap is 2 × cellW wide and the returned
    /// entry carries `cellSpan = 2` so the renderer can stretch its
    /// quad in atomic 3.
    func testClusterCellSpan2BitmapWidth() throws {
        let cluster = "\u{0E17}\u{0E33}"  // ทำ
        let entry = try atlas.entry(
            forCluster: cluster, cellSpan: 2, commandQueue: queue)
        XCTAssertEqual(entry.atlasIndex, 0, "Thai must stay in gray atlas")
        XCTAssertEqual(entry.cellSpan, 2)
        XCTAssertEqual(
            entry.sizePx.x, atlas.cellSizePx.x * 2,
            "cellSpan=2 entry must be 2 × cellW wide")
        XCTAssertEqual(entry.sizePx.y, atlas.cellSizePx.y)
    }

    /// The atlas cache keys (clusterString, cellSpan) distinctly: the
    /// same cluster requested twice at the same span hits one slot;
    /// the same cluster at a different span gets its own slot.
    func testClusterCacheDedupesByCellSpan() throws {
        let cluster = "\u{0E17}\u{0E33}"  // ทำ
        let span2a = try atlas.entry(
            forCluster: cluster, cellSpan: 2, commandQueue: queue)
        let span2b = try atlas.entry(
            forCluster: cluster, cellSpan: 2, commandQueue: queue)
        XCTAssertEqual(atlas.entryCount, 1, "same span: one slot")
        XCTAssertEqual(span2a.originPx, span2b.originPx)

        let span1 = try atlas.entry(
            forCluster: cluster, cellSpan: 1, commandQueue: queue)
        XCTAssertEqual(
            atlas.entryCount, 2, "different span: distinct slot")
        XCTAssertNotEqual(span1.originPx, span2a.originPx)
        XCTAssertEqual(span1.cellSpan, 1)
        XCTAssertEqual(span1.sizePx.x, atlas.cellSizePx.x)
    }

    /// Default cellSpan = 1 — existing call sites that don't pass the
    /// argument continue to rasterize at one cell wide (production
    /// bit-for-bit identical to v0.1.6 for the single-cluster path).
    func testClusterDefaultSpanIsOne() throws {
        let cluster = "\u{0E1E}\u{0E37}\u{0E48}"  // พื่
        let entry = try atlas.entry(
            forCluster: cluster, commandQueue: queue)
        XCTAssertEqual(entry.cellSpan, 1)
        XCTAssertEqual(entry.sizePx.x, atlas.cellSizePx.x)
    }

    /// Color emoji flag pair: RI + RI clusters route to the color
    /// atlas and the cellSpan=2 widening must apply there too, so the
    /// composed flag glyph isn't horizontally clipped.
    func testColorClusterCellSpan2BitmapWidth() throws {
        // 🇹🇭 — Thailand flag, two regional indicators.
        let cluster = "\u{1F1F9}\u{1F1ED}"
        let entry = try atlas.entry(
            forCluster: cluster, cellSpan: 2, commandQueue: queue)
        XCTAssertEqual(
            entry.atlasIndex, 1, "RI flag must land in color atlas")
        XCTAssertEqual(entry.cellSpan, 2)
        XCTAssertEqual(entry.sizePx.x, atlas.cellSizePx.x * 2)
        XCTAssertEqual(entry.sizePx.y, atlas.cellSizePx.y)
    }

    // MARK: - Fit-to-box (glyph clipping regression)

    /// `fitScale` is a pure function: a glyph already inside the box must
    /// return exactly 1.0 (no scaling → common ASCII/CJK path stays
    /// bit-identical), and a glyph overflowing any edge must return a
    /// factor < 1 that brings the offending extent back inside the box.
    func testFitScalePureMath() {
        let box: CGFloat = 10
        let ascent: CGFloat = 12
        let descent: CGFloat = 4

        // Fits on every axis → no scaling.
        XCTAssertEqual(
            GlyphAtlas.fitScale(
                bbox: CGRect(x: 1, y: 1, width: 8, height: 9),
                boxWidthPt: box, cellAscentPt: ascent, cellDescentPt: descent),
            1.0, accuracy: 1e-9)

        // Right overflow: maxX = 20 > box 10 → 0.5.
        XCTAssertEqual(
            GlyphAtlas.fitScale(
                bbox: CGRect(x: 0, y: 0, width: 20, height: 1),
                boxWidthPt: box, cellAscentPt: ascent, cellDescentPt: descent),
            0.5, accuracy: 1e-9)

        // Top overflow: maxY = 24 > ascent 12 → 0.5.
        XCTAssertEqual(
            GlyphAtlas.fitScale(
                bbox: CGRect(x: 0, y: 0, width: 1, height: 24),
                boxWidthPt: box, cellAscentPt: ascent, cellDescentPt: descent),
            0.5, accuracy: 1e-9)

        // Bottom overflow: minY = -8 < -descent 4 → 0.5.
        XCTAssertEqual(
            GlyphAtlas.fitScale(
                bbox: CGRect(x: 0, y: -8, width: 1, height: 4),
                boxWidthPt: box, cellAscentPt: ascent, cellDescentPt: descent),
            0.5, accuracy: 1e-9)

        // Never upscales: a tiny glyph stays at 1.0, not enlarged.
        XCTAssertEqual(
            GlyphAtlas.fitScale(
                bbox: CGRect(x: 0, y: 0, width: 1, height: 1),
                boxWidthPt: box, cellAscentPt: ascent, cellDescentPt: descent),
            1.0, accuracy: 1e-9)
    }

    /// Integration: a single-scalar glyph whose natural ink overflows
    /// one cell must be shrunk to fit, NOT clipped at the cell edge.
    ///
    /// We pick a scalar whose resolved fallback glyph genuinely exceeds
    /// the cell box on the running OS (confirmed via the bbox hook); if
    /// none overflows in this CT version we skip rather than assert a
    /// false negative. The contract: after fit-to-box the rasterized
    /// bitmap's outermost row/column must carry essentially no ink — the
    /// glyph was scaled inward, so its extreme edge no longer paints the
    /// boundary pixels that a clipped (over-box) draw would have
    /// saturated.
    func testWideGlyphShrinksToFitNotClipped() throws {
        // Candidate scalars that commonly resolve to wide/tall fallback
        // glyphs exceeding a Menlo cell: misc-symbols, dingbats, CJK
        // compatibility ideographs. Use the first that actually overflows
        // so the assertion exercises the fit path.
        let candidates: [Unicode.Scalar] = [
            Unicode.Scalar(0x2702)!,  // ✂ BLACK SCISSORS
            Unicode.Scalar(0x2728)!,  // ✨ SPARKLES (often color → skip)
            Unicode.Scalar(0x27A1)!,  // ➡ RIGHTWARDS ARROW
            Unicode.Scalar(0x2B50)!,  // ⭐ WHITE MEDIUM STAR
            Unicode.Scalar(0x3013)!,  // 〓 GETA MARK
            Unicode.Scalar(0xFFFD)!,  // � REPLACEMENT CHARACTER
        ]

        var chosen: Unicode.Scalar?
        for s in candidates {
            let (bbox, cellW, cellH) = try atlas._testGlyphBBoxAndCellPt(s)
            let overflowsX = bbox.maxX > cellW || bbox.minX < 0
            let overflowsY =
                bbox.maxY > CTFontGetAscent(atlas.font)
                || bbox.minY < -CTFontGetDescent(atlas.font)
            _ = cellH
            if overflowsX || overflowsY {
                chosen = s
                break
            }
        }
        guard let scalar = chosen else {
            throw XCTSkip(
                "no candidate glyph overflows the cell on this CT version")
        }

        let (bitmap, widthPx, heightPx) = try atlas._testRasterizeGlyphBitmap(
            scalar)
        XCTAssertEqual(bitmap.count, widthPx * heightPx)

        // Sum ink in the outermost ring (last column + last row). After a
        // correct shrink-to-fit the glyph no longer paints the boundary;
        // a clipped (unscaled, over-box) draw would saturate it.
        func columnInk(_ col: Int) -> Int {
            var t = 0
            for row in 0..<heightPx { t += Int(bitmap[row * widthPx + col]) }
            return t
        }
        func rowInk(_ row: Int) -> Int {
            var t = 0
            let base = row * widthPx
            for col in 0..<widthPx { t += Int(bitmap[base + col]) }
            return t
        }

        let lastCol = columnInk(widthPx - 1)
        let lastRow = rowInk(0)  // row 0 = visual top (top-down layout)
        // The whole-cell ink must be non-trivial (the glyph did render),
        // but the boundary ring must be near-empty (it was fit inward).
        // Allow a small antialiasing budget proportional to the edge
        // length rather than a hard zero.
        let totalInk = bitmap.reduce(0) { $0 + Int($1) }
        XCTAssertGreaterThan(
            totalInk, 0, "glyph \(scalar) must actually rasterize")
        let edgeBudget = 8 * max(widthPx, heightPx)  // ~8/255 avg per px
        XCTAssertLessThan(
            lastCol, edgeBudget,
            "right edge column must be near-empty after fit-to-box "
                + "(got \(lastCol)) — glyph \(scalar) appears clipped")
        XCTAssertLessThan(
            lastRow, edgeBudget,
            "top edge row must be near-empty after fit-to-box "
                + "(got \(lastRow)) — glyph \(scalar) appears clipped")
    }
}
