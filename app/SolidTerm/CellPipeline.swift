// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Stage 0 MSL pipeline — owns the
// `MTLRenderPipelineState` for the cell vertex+fragment shaders and
// encodes a single-glyph draw call against a bound `GlyphAtlas`.
//
// 3.8 scope: one cell, one glyph, one draw call. 3.9 lands the
// full-screen quad pattern that draws the entire 80×24 grid in a
// single dispatch.

import Metal
import simd

/// Memory layout MUST match `CellUniforms` in `Shaders.metal`. Keep
/// fields in the same order, same type widths.
struct CellUniforms {
    var screenSizePx: SIMD2<Float>
    var cellSizePx: SIMD2<Float>
    var cellOriginPx: SIMD2<Float>
    var atlasOriginUV: SIMD2<Float>
    var atlasSizeUV: SIMD2<Float>
    var fgColorLinear: SIMD4<Float>
    var bgColorLinear: SIMD4<Float>
}

/// One cell to render this frame. Single-glyph spike-only struct;
/// 3.9's full-screen pass replaces this with a `cellFG/cellBG/cellAtlas`
/// texture trio.
struct CellDraw {
    let cellCol: Int
    let cellRow: Int
    let entry: AtlasEntry
    let fgColorLinear: SIMD4<Float>
    let bgColorLinear: SIMD4<Float>
}

final class CellPipeline {
    let device: MTLDevice
    let pipelineState: MTLRenderPipelineState

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        guard let library = device.makeDefaultLibrary() else {
            throw PipelineError.libraryUnavailable
        }
        guard let vfn = library.makeFunction(name: "cell_vertex"),
            let ffn = library.makeFunction(name: "cell_fragment")
        else {
            throw PipelineError.functionMissing
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "CellPipeline"
        descriptor.vertexFunction = vfn
        descriptor.fragmentFunction = ffn
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        // No alpha blending: the fragment shader does the linear-space
        // mix(bg, fg, alpha) itself and stores the result opaque.
        descriptor.colorAttachments[0].isBlendingEnabled = false

        self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    enum PipelineError: Error {
        case libraryUnavailable
        case functionMissing
    }

    /// Encode one quad draw against `encoder`. Caller already opened the
    /// render pass on a clear-loaded color attachment; we only add the
    /// glyph quad on top.
    func encode(
        _ draw: CellDraw,
        atlas: GlyphAtlas,
        drawableSize: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        let cellPx = SIMD2<Float>(
            Float(atlas.cellSizePx.x),
            Float(atlas.cellSizePx.y))
        let originPx = SIMD2<Float>(
            Float(draw.cellCol) * cellPx.x,
            Float(draw.cellRow) * cellPx.y)
        let atlasUVOrigin = draw.entry.uvOrigin(atlasSize: GlyphAtlas.atlasSize)
        let atlasUVSize = draw.entry.uvSize(atlasSize: GlyphAtlas.atlasSize)
        var uniforms = CellUniforms(
            screenSizePx: SIMD2<Float>(
                Float(drawableSize.width), Float(drawableSize.height)),
            cellSizePx: cellPx,
            cellOriginPx: originPx,
            atlasOriginUV: atlasUVOrigin,
            atlasSizeUV: atlasUVSize,
            fgColorLinear: draw.fgColorLinear,
            bgColorLinear: draw.bgColorLinear)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CellUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CellUniforms>.stride, index: 0)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
