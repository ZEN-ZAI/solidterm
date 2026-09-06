// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Stage 1 cell pass (full-screen quad)
// — owns the `MTLRenderPipelineState` for the grid shaders, the three
// per-cell textures (cellFG / cellBG / cellAtlasUV), and the encode
// path that draws the entire grid in a single 4-vertex triangle strip.
//
// Stage-1 scope (3.9): renders a static `[CellSlot]` grid of glyphs.
// Damage tracking (`dirtyRows` discard) and FrameDelta-driven updates
// land at 3.7 / #17. Atlas selector for color emoji at 4.x.

import Metal
import simd

/// One cell's render input. Optional `glyph` so blank cells can render
/// pure background without occupying an atlas slot. The renderer
/// converts `[CellSlot]` arrays into the three per-cell texture
/// uploads in `GridPipeline.setGrid`.
struct CellSlot {
    var glyph: AtlasEntry?
    var fgColorLinear: SIMD4<Float>
    var bgColorLinear: SIMD4<Float>
    /// alacritty `cell::Flags` low byte: INVERSE=0x01, BOLD=0x02,
    /// ITALIC=0x04, UNDERLINE=0x08. Carried through so the overlay
    /// pass can render underline runs without re-walking the FFI delta.
    var attrs: UInt16 = 0

    static func blank(bgColorLinear: SIMD4<Float>) -> CellSlot {
        CellSlot(glyph: nil, fgColorLinear: SIMD4(0, 0, 0, 0), bgColorLinear: bgColorLinear)
    }
}

/// Memory layout MUST match `GridUniforms` in `Shaders.metal`. Field
/// order, sizes, and alignment are the cross-language contract.
struct GridUniforms {
    var screenSizePx: SIMD2<Float>
    var cellSizePx: SIMD2<Float>
    var atlasSizePx: SIMD2<Float>
    var gridSizeCells: SIMD2<UInt32>
    var gridOriginPx: SIMD2<Float>
    var colorAtlasSizePx: SIMD2<Float>
    /// Block-cursor reverse-video (cursor visibility fix). The grid pass
    /// reverse-videos the cursor cell in `grid_fragment` instead of the
    /// overlay pass painting an opaque block that hides the glyph. Field
    /// order / SIMD alignment MUST match `GridUniforms` in `Shaders.metal`.
    /// `cursorBlockActive == 0` (the default below) leaves the steady-state
    /// render unchanged; only a visible, on-screen BLOCK cursor flips it to
    /// 1. Beam / underline cursors keep using the overlay quad.
    var cursorCell: SIMD2<UInt32> = SIMD2(0, 0)
    var cursorColorLinear: SIMD4<Float> = SIMD4(0, 0, 0, 0)
    var cursorBlockAlpha: Float = 0
    var cursorBlockActive: UInt32 = 0
}

final class GridPipeline {
    let device: MTLDevice
    let pipelineState: MTLRenderPipelineState
    let cols: Int
    let rows: Int

    private let cellFG: MTLTexture
    private let cellBG: MTLTexture
    private let cellAtlasUV: MTLTexture
    /// Per-cell packed byte pair (r16Uint texture):
    ///   - low  byte = atlas selector (0 = grayscale atlas, 1 = color emoji atlas)
    ///   - high byte = `cellSpan` (1 = single-cell glyph, N = primary cell of an
    ///     N-wide cross-cell cluster, 0 = continuation cell owned by a primary
    ///     to its left)
    ///
    /// Widened from r8Uint to r16Uint by ADR-0003
    /// (atomic 3, on top of coalescer `4a23339`) so a single cluster glyph can
    /// paint across multiple cell columns (Thai SARA AM, regional indicator
    /// flag pairs, ZWJ spillovers). Production cells continue to land with
    /// `cellSpan = 1` until atomic 4 wires the `[CoalescedCell]` path into
    /// `MetalRenderer.applyCellsAsRegions`; with span=1 everywhere the shader
    /// walks the same code path as pre-r16 and pixels are byte-identical.
    private let cellAtlasSelector: MTLTexture

    init(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        cols: Int,
        rows: Int
    ) throws {
        precondition(cols > 0 && rows > 0, "grid must have positive dimensions")
        self.device = device
        self.cols = cols
        self.rows = rows

        guard let library = device.makeDefaultLibrary() else {
            throw PipelineError.libraryUnavailable
        }
        guard let vfn = library.makeFunction(name: "grid_vertex"),
            let ffn = library.makeFunction(name: "grid_fragment")
        else {
            throw PipelineError.functionMissing
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "GridPipeline"
        descriptor.vertexFunction = vfn
        descriptor.fragmentFunction = ffn
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = false
        self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        // Per-cell textures, sized to the grid. Shared storage for direct
        // CPU writes — Apple Silicon UMA makes this zero-copy. When
        // FrameDelta drives per-frame mutations at #17, profile shared-
        // storage thrash; switch to .private + staging if measurement
        // shows overhead.
        self.cellFG = try Self.makeCellTexture(
            device: device, format: .rgba8Unorm, cols: cols, rows: rows,
            label: "GridPipeline.cellFG")
        self.cellBG = try Self.makeCellTexture(
            device: device, format: .rgba8Unorm, cols: cols, rows: rows,
            label: "GridPipeline.cellBG")
        self.cellAtlasUV = try Self.makeCellTexture(
            device: device, format: .rg16Unorm, cols: cols, rows: rows,
            label: "GridPipeline.cellAtlasUV")
        self.cellAtlasSelector = try Self.makeCellTexture(
            device: device, format: .r16Uint, cols: cols, rows: rows,
            label: "GridPipeline.cellAtlasSelector")
    }

    enum PipelineError: Error {
        case libraryUnavailable
        case functionMissing
        case textureAllocFailed
        case gridSizeMismatch(expected: Int, actual: Int)
        case regionOutOfBounds(rect: GridRect, cols: Int, rows: Int)
    }

    /// Rectangular region of the cell grid, in cell coordinates. Used by
    /// `setRegion` to identify the destination of a packed slot upload.
    /// `col` / `row` are the top-left origin; `width` / `height` are
    /// extents in cells. All values are non-negative; the rect must lie
    /// fully inside `[0, cols) × [0, rows)`.
    struct GridRect: Equatable {
        var col: Int
        var row: Int
        var width: Int
        var height: Int
    }

    /// Upload a flat row-major `[CellSlot]` into the three per-cell
    /// textures. `cells.count` MUST equal `cols * rows` — the array is
    /// indexed as `cells[row * cols + col]`.
    func setGrid(
        _ cells: [CellSlot],
        atlasSize: SIMD2<UInt32>,
        colorAtlasSize: SIMD2<UInt32>? = nil
    ) throws {
        let expected = cols * rows
        guard cells.count == expected else {
            throw PipelineError.gridSizeMismatch(expected: expected, actual: cells.count)
        }

        var fgBytes = [UInt8](repeating: 0, count: expected * 4)
        var bgBytes = [UInt8](repeating: 0, count: expected * 4)
        var uvBytes = [UInt16](repeating: 0, count: expected * 2)
        var selectorBytes = [UInt16](repeating: 0, count: expected)

        for (i, slot) in cells.enumerated() {
            let fgBase = i * 4
            fgBytes[fgBase + 0] = unitToByte(slot.fgColorLinear.x)
            fgBytes[fgBase + 1] = unitToByte(slot.fgColorLinear.y)
            fgBytes[fgBase + 2] = unitToByte(slot.fgColorLinear.z)
            fgBytes[fgBase + 3] = unitToByte(slot.fgColorLinear.w)

            let bgBase = i * 4
            bgBytes[bgBase + 0] = unitToByte(slot.bgColorLinear.x)
            bgBytes[bgBase + 1] = unitToByte(slot.bgColorLinear.y)
            bgBytes[bgBase + 2] = unitToByte(slot.bgColorLinear.z)
            bgBytes[bgBase + 3] = unitToByte(slot.bgColorLinear.w)

            let uvBase = i * 2
            if let entry = slot.glyph {
                // Color emoji entries normalize their UV against the
                // color atlas's dimensions, not the gray atlas's.
                let normSize: SIMD2<UInt32> =
                    entry.atlasIndex == 1
                    ? (colorAtlasSize ?? atlasSize)
                    : atlasSize
                let originUV = entry.uvOrigin(atlasSize: normSize)
                uvBytes[uvBase + 0] = unitToShort(originUV.x)
                uvBytes[uvBase + 1] = unitToShort(originUV.y)
                selectorBytes[i] = packSelector(
                    atlasIndex: entry.atlasIndex, cellSpan: entry.cellSpan)
            }
            // Blank cells leave `(0, 0)` UV + packed selector 0. With
            // cellSpan=0 in the high byte the shader treats them as
            // continuation/empty and samples atlas origin (alpha=0 →
            // mix(bg, fg, 0) = bg).
        }

        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: cols, height: rows, depth: 1))

        fgBytes.withUnsafeBytes { ptr in
            cellFG.replace(
                region: region, mipmapLevel: 0,
                withBytes: ptr.baseAddress!, bytesPerRow: cols * 4)
        }
        bgBytes.withUnsafeBytes { ptr in
            cellBG.replace(
                region: region, mipmapLevel: 0,
                withBytes: ptr.baseAddress!, bytesPerRow: cols * 4)
        }
        uvBytes.withUnsafeBytes { ptr in
            cellAtlasUV.replace(
                region: region, mipmapLevel: 0,
                withBytes: ptr.baseAddress!, bytesPerRow: cols * 2 * 2)
        }
        selectorBytes.withUnsafeBytes { ptr in
            cellAtlasSelector.replace(
                region: region, mipmapLevel: 0,
                withBytes: ptr.baseAddress!, bytesPerRow: cols * 2)
        }
    }

    /// Update a rectangular region of the grid in a single packed
    /// upload — three `replace(region:)` calls (FG, BG, UV) instead of
    /// 3·N for N independent cells. Designed for the FFI cell stream
    /// from `take_frame_delta`, where many cells from one PTY chunk
    /// land in the same frame; grouping them by row-contiguous run and
    /// pushing each run through `setRegion` cuts per-frame Metal
    /// driver overhead well below the per-cell `setCell` path.
    ///
    /// `slots` is a flat row-major array packed inside the rect:
    /// `slots[r * rect.width + c]` is the cell at
    /// `(rect.row + r, rect.col + c)`. The rect must lie fully inside
    /// the grid; out-of-bounds rects throw `regionOutOfBounds`.
    /// `slots.count` must equal `rect.width * rect.height`.
    ///
    /// Single-cell mutations (the keystroke-spike path) still go through
    /// `setCell`; this API is for the multi-cell FrameDelta consumer
    /// where avoiding three `replace` calls per cell matters.
    func setRegion(
        rect: GridRect,
        slots: [CellSlot],
        atlasSize: SIMD2<UInt32>,
        colorAtlasSize: SIMD2<UInt32>? = nil
    ) throws {
        guard rect.width > 0, rect.height > 0,
            rect.col >= 0, rect.row >= 0,
            rect.col + rect.width <= cols,
            rect.row + rect.height <= rows
        else {
            throw PipelineError.regionOutOfBounds(rect: rect, cols: cols, rows: rows)
        }
        let expected = rect.width * rect.height
        guard slots.count == expected else {
            throw PipelineError.gridSizeMismatch(expected: expected, actual: slots.count)
        }

        var fgBytes = [UInt8](repeating: 0, count: expected * 4)
        var bgBytes = [UInt8](repeating: 0, count: expected * 4)
        var uvBytes = [UInt16](repeating: 0, count: expected * 2)
        var selectorBytes = [UInt16](repeating: 0, count: expected)

        for (i, slot) in slots.enumerated() {
            let fgBase = i * 4
            fgBytes[fgBase + 0] = unitToByte(slot.fgColorLinear.x)
            fgBytes[fgBase + 1] = unitToByte(slot.fgColorLinear.y)
            fgBytes[fgBase + 2] = unitToByte(slot.fgColorLinear.z)
            fgBytes[fgBase + 3] = unitToByte(slot.fgColorLinear.w)

            let bgBase = i * 4
            bgBytes[bgBase + 0] = unitToByte(slot.bgColorLinear.x)
            bgBytes[bgBase + 1] = unitToByte(slot.bgColorLinear.y)
            bgBytes[bgBase + 2] = unitToByte(slot.bgColorLinear.z)
            bgBytes[bgBase + 3] = unitToByte(slot.bgColorLinear.w)

            let uvBase = i * 2
            if let entry = slot.glyph {
                let normSize: SIMD2<UInt32> =
                    entry.atlasIndex == 1
                    ? (colorAtlasSize ?? atlasSize)
                    : atlasSize
                let originUV = entry.uvOrigin(atlasSize: normSize)
                uvBytes[uvBase + 0] = unitToShort(originUV.x)
                uvBytes[uvBase + 1] = unitToShort(originUV.y)
                selectorBytes[i] = packSelector(
                    atlasIndex: entry.atlasIndex, cellSpan: entry.cellSpan)
            }
            // Blank cells leave (0, 0) UV + packed selector 0.
        }

        let region = MTLRegion(
            origin: MTLOrigin(x: rect.col, y: rect.row, z: 0),
            size: MTLSize(width: rect.width, height: rect.height, depth: 1))

        fgBytes.withUnsafeBytes { ptr in
            cellFG.replace(
                region: region, mipmapLevel: 0,
                withBytes: ptr.baseAddress!, bytesPerRow: rect.width * 4)
        }
        bgBytes.withUnsafeBytes { ptr in
            cellBG.replace(
                region: region, mipmapLevel: 0,
                withBytes: ptr.baseAddress!, bytesPerRow: rect.width * 4)
        }
        uvBytes.withUnsafeBytes { ptr in
            cellAtlasUV.replace(
                region: region, mipmapLevel: 0,
                withBytes: ptr.baseAddress!, bytesPerRow: rect.width * 2 * 2)
        }
        selectorBytes.withUnsafeBytes { ptr in
            cellAtlasSelector.replace(
                region: region, mipmapLevel: 0,
                withBytes: ptr.baseAddress!, bytesPerRow: rect.width * 2)
        }
    }

    /// Update one cell in place — three 1×1 `replace(region:)` calls
    /// instead of rewriting the whole 1920-cell texture trio. Renderer
    /// uses this for per-keystroke mutations to keep the typing-to-pixel
    /// path off the full-grid upload cost (~3.5 ms p99 per keystroke
    /// at 80×24, measured during 3.10 baseline).
    ///
    /// `index` is row-major: `cells[row * cols + col]`. Bounds-checked
    /// at runtime; out-of-range indices throw `gridSizeMismatch` so
    /// callers can't silently corrupt the texture.
    func setCell(
        at index: Int,
        slot: CellSlot,
        atlasSize: SIMD2<UInt32>,
        colorAtlasSize: SIMD2<UInt32>? = nil
    ) throws {
        let total = cols * rows
        guard index >= 0, index < total else {
            throw PipelineError.gridSizeMismatch(expected: total, actual: index)
        }
        let col = index % cols
        let row = index / cols

        var fg: [UInt8] = [
            unitToByte(slot.fgColorLinear.x),
            unitToByte(slot.fgColorLinear.y),
            unitToByte(slot.fgColorLinear.z),
            unitToByte(slot.fgColorLinear.w),
        ]
        var bg: [UInt8] = [
            unitToByte(slot.bgColorLinear.x),
            unitToByte(slot.bgColorLinear.y),
            unitToByte(slot.bgColorLinear.z),
            unitToByte(slot.bgColorLinear.w),
        ]
        var uv: [UInt16] = [0, 0]
        var selector: [UInt16] = [0]
        if let entry = slot.glyph {
            let normSize: SIMD2<UInt32> =
                entry.atlasIndex == 1
                ? (colorAtlasSize ?? atlasSize)
                : atlasSize
            let originUV = entry.uvOrigin(atlasSize: normSize)
            uv[0] = unitToShort(originUV.x)
            uv[1] = unitToShort(originUV.y)
            selector[0] = packSelector(atlasIndex: entry.atlasIndex, cellSpan: entry.cellSpan)
        }

        let region = MTLRegion(
            origin: MTLOrigin(x: col, y: row, z: 0),
            size: MTLSize(width: 1, height: 1, depth: 1))
        fg.withUnsafeBytes { ptr in
            cellFG.replace(
                region: region, mipmapLevel: 0,
                withBytes: ptr.baseAddress!, bytesPerRow: 4)
        }
        bg.withUnsafeBytes { ptr in
            cellBG.replace(
                region: region, mipmapLevel: 0,
                withBytes: ptr.baseAddress!, bytesPerRow: 4)
        }
        uv.withUnsafeBytes { ptr in
            cellAtlasUV.replace(
                region: region, mipmapLevel: 0,
                withBytes: ptr.baseAddress!, bytesPerRow: 4)
        }
        selector.withUnsafeBytes { ptr in
            cellAtlasSelector.replace(
                region: region, mipmapLevel: 0,
                withBytes: ptr.baseAddress!, bytesPerRow: 2)
        }
    }

    /// Encode the grid pass against `encoder`. Caller has already opened
    /// the render pass on a clear-loaded color attachment; we add the
    /// full-screen quad on top.
    func encode(
        uniforms: GridUniforms,
        atlas: GlyphAtlas,
        encoder: MTLRenderCommandEncoder
    ) {
        var u = uniforms
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&u, length: MemoryLayout<GridUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<GridUniforms>.stride, index: 0)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.setFragmentTexture(cellFG, index: 1)
        encoder.setFragmentTexture(cellBG, index: 2)
        encoder.setFragmentTexture(cellAtlasUV, index: 3)
        encoder.setFragmentTexture(atlas.colorTexture, index: 4)
        encoder.setFragmentTexture(cellAtlasSelector, index: 5)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - Helpers

    private static func makeCellTexture(
        device: MTLDevice,
        format: MTLPixelFormat,
        cols: Int,
        rows: Int,
        label: String
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: cols, height: rows,
            mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PipelineError.textureAllocFailed
        }
        texture.label = label
        return texture
    }

    private func unitToByte(_ value: Float) -> UInt8 {
        let clamped = max(0.0, min(1.0, value))
        return UInt8((clamped * 255.0).rounded())
    }

    private func unitToShort(_ value: Float) -> UInt16 {
        let clamped = max(0.0, min(1.0, value))
        return UInt16((clamped * 65535.0).rounded())
    }

    /// Packs the per-cell `cellAtlasSelector` r16Uint sample:
    ///   - low  byte = atlas selector (0 grayscale / 1 color emoji)
    ///   - high byte = cellSpan (1 = single-cell primary, N = N-wide primary,
    ///     0 = blank or continuation)
    /// See ADR-0003. Mirrors the shader
    /// decode in `Shaders.metal` (`grid_fragment`).
    private func packSelector(atlasIndex: UInt8, cellSpan: UInt8) -> UInt16 {
        return UInt16(atlasIndex) | (UInt16(cellSpan) << 8)
    }
}
