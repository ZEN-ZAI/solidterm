// Verifies the block-cursor reverse-video fix (cursor visibility bug:
// "สี cursor ทับตัวอักษรทำให้มองไม่เห็น" — the opaque block cursor used to
// paint over the glyph and hide the character under it).
//
// The fix moves the BLOCK cursor out of the overlay pass (which drew an
// opaque quad over the already-rendered glyph) and into the grid pass,
// which reverse-videos the cursor cell: the cell fills with the cursor
// colour and the glyph is redrawn in the cell's background colour, so it
// stays readable. See `grid_fragment` in `Shaders.metal` + the
// `cursorBlock*` fields on `GridUniforms`.
//
// Strategy mirrors `OverlayPipelineTests.testCursorShapesRenderExpectedGeometry`:
// render the real grid pass into an offscreen `.rgba8Unorm` target (no
// sRGB encode-on-store, so linear values read back as the bytes we wrote)
// and sample pixels. A box-drawing glyph (U+2500 ─, a single horizontal
// line at the cell's vertical mid-row) is used as the known glyph because
// `BoxDrawing.rasterize` paints it procedurally at exact cell metrics —
// deterministic coverage independent of the installed font cascade.
//
// The two load-bearing assertions:
//   1. On a glyph cell under the block cursor, the glyph's line row reads
//      the CONTRAST colour (reversed fg), NOT a uniform cursor-colour
//      block — i.e. the character is visible. This is the regression that
//      reproduces the reported bug if the fix is reverted.
//   2. On an EMPTY cell under the block cursor, the whole cell reads the
//      solid cursor colour (a plain block, as expected).

import CoreText
import Metal
import XCTest
import simd

@testable import SolidTerm

final class GridCursorReverseVideoTests: XCTestCase {

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var atlas: GlyphAtlas!

    // A 2-column, 1-row grid. Cell metrics come from the atlas; we keep
    // contentsScale = 1 so the cell pixel box is small and the box-drawing
    // line geometry is predictable.
    private let cols = 2
    private let rows = 1

    override func setUpWithError() throws {
        // Guard exactly like the other renderer tests: CI / headless shells
        // may lack a Metal device.
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        device = dev
        queue = try XCTUnwrap(device.makeCommandQueue())
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 14, nil)
        atlas = try GlyphAtlas(device: device, font: font, contentsScale: 1.0)
    }

    override func tearDown() {
        atlas = nil
        queue = nil
        device = nil
    }

    /// Cursor colour (green), cell fg (white), cell bg (black) are mutually
    /// distinct so each can be detected by channel. Linear values; with the
    /// `.rgba8Unorm` (non-sRGB) target they read back unchanged.
    private let cursorGreen = SIMD4<Float>(0, 1, 0, 1)
    private let fgWhite = SIMD4<Float>(1, 1, 1, 1)
    private let bgBlack = SIMD4<Float>(0, 0, 0, 1)

    // MARK: - Tests

    /// A block cursor over a glyph cell must reverse-video: cell filled with
    /// the cursor colour, glyph redrawn in the cell's background colour. The
    /// glyph's line row therefore reads the bg colour (black here) — the
    /// character stays visible — while the surrounding cell reads the cursor
    /// colour (green). A uniform green block (the pre-fix bug) would read
    /// green at the line row too, which this test rejects.
    func testBlockCursorReverseVideoKeepsGlyphVisible() throws {
        let cellW = Int(atlas.cellSizePx.x)
        let cellH = Int(atlas.cellSizePx.y)

        // Cell 0 carries the ─ glyph (horizontal line at vertical mid-row);
        // cell 1 stays blank. Cursor sits on cell 0.
        let lineEntry = try atlas.entry(for: "\u{2500}", commandQueue: queue)
        let glyphSlot = CellSlot(
            glyph: lineEntry, fgColorLinear: fgWhite, bgColorLinear: bgBlack)
        let blankSlot = CellSlot.blank(bgColorLinear: bgBlack)

        let pixels = try renderGrid(
            slots: [glyphSlot, blankSlot],
            cursorCell: SIMD2<UInt32>(0, 0))

        let cx = cellW / 2
        let midY = cellH / 2  // box-drawing `cy`: the ─ line row

        // Margin of the cursor cell (top row, above the line) → cursor fill.
        // Use y = 1 to stay clear of any bilinear softening at the line.
        assertGreen(pixels, x: cx, y: 1, label: "cursor cell margin (fill)")

        // The glyph's line row → reversed fg = the cell bg (black). This is
        // the visibility guarantee: NOT the cursor colour.
        let lineIdx = pixelIndex(x: cx, y: midY)
        XCTAssertLessThan(
            pixels[lineIdx + 1], 60,
            "glyph row must be the contrast colour (dark), not a green cursor block")
        assertBlack(pixels, x: cx, y: midY, label: "cursor cell glyph line (contrast)")

        // Sanity: the glyph cell must NOT be a uniform cursor block. At least
        // one sampled pixel inside the cell is the contrast colour.
        XCTAssertFalse(
            isGreen(pixels, x: cx, y: midY),
            "glyph line under the cursor must not read as the cursor colour")
    }

    /// A block cursor over an EMPTY cell paints a solid cursor-colour block
    /// (there is no glyph to reverse). Every sampled pixel in the cell reads
    /// the cursor colour.
    func testBlockCursorOnEmptyCellIsSolidBlock() throws {
        let cellW = Int(atlas.cellSizePx.x)
        let cellH = Int(atlas.cellSizePx.y)

        // Cell 0 blank, cell 1 blank; cursor on cell 1 (the empty cell).
        let blank0 = CellSlot.blank(bgColorLinear: bgBlack)
        let blank1 = CellSlot.blank(bgColorLinear: bgBlack)

        let pixels = try renderGrid(
            slots: [blank0, blank1],
            cursorCell: SIMD2<UInt32>(1, 0))

        // Sample several points inside cell 1 — all must be the solid cursor
        // colour (green).
        let baseX = cellW  // cell 1 starts one cell to the right
        assertGreen(pixels, x: baseX + cellW / 2, y: 1, label: "empty cell top")
        assertGreen(pixels, x: baseX + cellW / 2, y: cellH / 2, label: "empty cell mid")
        assertGreen(pixels, x: baseX + cellW / 2, y: cellH - 1, label: "empty cell bottom")
        assertGreen(pixels, x: baseX + 1, y: cellH / 2, label: "empty cell left")

        // Cell 0 (no cursor) must remain the plain bg (black), proving the
        // reverse-video only touches the cursor cell.
        assertBlack(pixels, x: cellW / 2, y: cellH / 2, label: "non-cursor cell stays bg")
    }

    /// With `cursorBlockActive == 0` (no block cursor) the cursor cell is
    /// untouched — the glyph renders normally (white on black). Pins that
    /// the new uniform path is inert in the steady state.
    func testNoCursorLeavesGlyphUnchanged() throws {
        let cellW = Int(atlas.cellSizePx.x)
        let cellH = Int(atlas.cellSizePx.y)

        let lineEntry = try atlas.entry(for: "\u{2500}", commandQueue: queue)
        let glyphSlot = CellSlot(
            glyph: lineEntry, fgColorLinear: fgWhite, bgColorLinear: bgBlack)
        let blankSlot = CellSlot.blank(bgColorLinear: bgBlack)

        // cursorBlockActive stays 0 (nil cursor cell argument).
        let pixels = try renderGrid(
            slots: [glyphSlot, blankSlot], cursorCell: nil)

        let cx = cellW / 2
        let midY = cellH / 2
        // Normal render: glyph (fg=white) on the line row, bg (black) margin.
        assertWhite(pixels, x: cx, y: midY, label: "glyph line normal (fg)")
        assertBlack(pixels, x: cx, y: 1, label: "glyph margin normal (bg)")
    }

    // MARK: - Render harness

    /// Render the grid pass into an offscreen `.rgba8Unorm` target with the
    /// given cell slots and (optionally) a block cursor, returning the RGBA
    /// byte buffer. `cursorCell == nil` leaves `cursorBlockActive = 0`.
    private func renderGrid(
        slots: [CellSlot],
        cursorCell: SIMD2<UInt32>?
    ) throws -> [UInt8] {
        let pipeline = try GridPipeline(
            device: device, pixelFormat: .rgba8Unorm, cols: cols, rows: rows)
        try pipeline.setGrid(
            slots,
            atlasSize: atlas.atlasSize,
            colorAtlasSize: atlas.colorAtlasSize)

        let cellW = Int(atlas.cellSizePx.x)
        let cellH = Int(atlas.cellSizePx.y)
        let widthPx = cellW * cols
        let heightPx = cellH * rows

        let renderDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: widthPx, height: heightPx, mipmapped: false)
        renderDesc.usage = [.renderTarget, .shaderRead]
        renderDesc.storageMode = .private
        let renderTarget = try XCTUnwrap(device.makeTexture(descriptor: renderDesc))

        let readDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: widthPx, height: heightPx, mipmapped: false)
        readDesc.usage = [.shaderRead]
        readDesc.storageMode = .shared
        let readback = try XCTUnwrap(device.makeTexture(descriptor: readDesc))

        var uniforms = GridUniforms(
            screenSizePx: SIMD2<Float>(Float(widthPx), Float(heightPx)),
            cellSizePx: SIMD2<Float>(Float(cellW), Float(cellH)),
            atlasSizePx: SIMD2<Float>(
                Float(atlas.atlasSize.x), Float(atlas.atlasSize.y)),
            gridSizeCells: SIMD2<UInt32>(UInt32(cols), UInt32(rows)),
            gridOriginPx: SIMD2<Float>(0, 0),
            colorAtlasSizePx: SIMD2<Float>(
                Float(atlas.colorAtlasSize.x), Float(atlas.colorAtlasSize.y)))
        if let cell = cursorCell {
            uniforms.cursorCell = cell
            uniforms.cursorColorLinear = cursorGreen
            uniforms.cursorBlockAlpha = 1.0
            uniforms.cursorBlockActive = 1
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = renderTarget
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1)

        let buf = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(buf.makeRenderCommandEncoder(descriptor: pass))
        pipeline.encode(uniforms: uniforms, atlas: atlas, encoder: enc)
        enc.endEncoding()

        let blit = try XCTUnwrap(buf.makeBlitCommandEncoder())
        blit.copy(
            from: renderTarget,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: widthPx, height: heightPx, depth: 1),
            to: readback,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        buf.commit()
        buf.waitUntilCompleted()
        XCTAssertNil(buf.error)

        var pixels = [UInt8](repeating: 0, count: widthPx * heightPx * 4)
        pixels.withUnsafeMutableBufferPointer { ptr in
            readback.getBytes(
                ptr.baseAddress!,
                bytesPerRow: widthPx * 4,
                from: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: widthPx, height: heightPx, depth: 1)),
                mipmapLevel: 0)
        }
        self.lastWidthPx = widthPx
        return pixels
    }

    /// Row stride for `pixelIndex`, captured by the most recent render.
    private var lastWidthPx = 0

    @inline(__always)
    private func pixelIndex(x: Int, y: Int) -> Int {
        (y * lastWidthPx + x) * 4
    }

    @inline(__always)
    private func isGreen(_ p: [UInt8], x: Int, y: Int) -> Bool {
        let i = pixelIndex(x: x, y: y)
        return p[i] < 60 && p[i + 1] > 195 && p[i + 2] < 60
    }

    private func assertGreen(
        _ p: [UInt8], x: Int, y: Int, label: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        let i = pixelIndex(x: x, y: y)
        XCTAssertLessThan(p[i], 60, "\(label): R", file: file, line: line)
        XCTAssertGreaterThan(p[i + 1], 195, "\(label): G", file: file, line: line)
        XCTAssertLessThan(p[i + 2], 60, "\(label): B", file: file, line: line)
    }

    private func assertBlack(
        _ p: [UInt8], x: Int, y: Int, label: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        let i = pixelIndex(x: x, y: y)
        XCTAssertLessThan(p[i], 60, "\(label): R", file: file, line: line)
        XCTAssertLessThan(p[i + 1], 60, "\(label): G", file: file, line: line)
        XCTAssertLessThan(p[i + 2], 60, "\(label): B", file: file, line: line)
    }

    private func assertWhite(
        _ p: [UInt8], x: Int, y: Int, label: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        let i = pixelIndex(x: x, y: y)
        XCTAssertGreaterThan(p[i], 195, "\(label): R", file: file, line: line)
        XCTAssertGreaterThan(p[i + 1], 195, "\(label): G", file: file, line: line)
        XCTAssertGreaterThan(p[i + 2], 195, "\(label): B", file: file, line: line)
    }
}
