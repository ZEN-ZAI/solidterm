// Implements spec/metal-renderer.md §Stage 2 Overlay Pass — owns the
// `MTLRenderPipelineState` for the unified overlay shaders (one MSL
// fragment, `kind` discriminator) used to draw the cursor (4.7),
// selection (4.5), and IME marked-text underline (4.9) on top of the
// Stage-1 grid pass.
//
// 4.7 wired cursor; 4.5 wired selection; 4.9 wires IME underline.
// All four kinds share this single pipeline. Kind values:
//   0 = cursor block      (full-cell rect)
//   1 = cursor beam       (left ~12% of cell)
//   2 = selection         (full-cell tint at colorLinear.a alpha)
//   3 = IME underline     (bottom ~15% of cell, under preedit cells)
//   4 = cursor underline  (bottom ~15% of cell — extends the spec's
//                          enum; DECSCUSR has 4 shapes, the spec
//                          snippet at metal-renderer.md:358-375 only
//                          listed cursor block + beam)
//
// Blending: source-over straight alpha so `alpha=0` (blink-off phase)
// composes to "no visible change" against the grid pass's stored
// pixels.

import Metal
import simd

/// Memory layout MUST match `OverlayUniforms` in `Shaders.metal`. Field
/// order, sizes, and SIMD alignment are the cross-language contract.
///
/// 4.5 added `cellSpanCols`: how many cells wide the quad is along the
/// x-axis. Single-cell overlays (cursor block / beam / underline, IME
/// underline) leave this at 1; selection encode emits one quad per row
/// with the span set to the row's covered column count. The vertex
/// shader multiplies the quad's x-extent by `cellSpanCols`; y stays
/// single-cell and multi-row selections emit one quad per row.
struct OverlayUniforms {
    var screenSizePx: SIMD2<Float>
    var cellOriginPx: SIMD2<Float>
    var cellSizePx: SIMD2<Float>
    var colorLinear: SIMD4<Float>
    var kind: UInt32
    var alpha: Float
    var cellSpanCols: UInt32
}

/// Discriminator for the unified overlay fragment shader. 4.5 wires
/// `selection`; the IME-underline case is reserved (and discards in MSL)
/// until 4.9.
enum OverlayKind: UInt32 {
    case cursorBlock = 0
    case cursorBeam = 1
    case selection = 2
    case imeUnderline = 3  // 4.9: bottom ~15% of cell, drawn under preedit cells
    case cursorUnderline = 4
}

final class OverlayPipeline {
    let device: MTLDevice
    let pipelineState: MTLRenderPipelineState

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        guard let library = device.makeDefaultLibrary() else {
            throw PipelineError.libraryUnavailable
        }
        guard let vfn = library.makeFunction(name: "overlay_vertex"),
            let ffn = library.makeFunction(name: "overlay_fragment")
        else {
            throw PipelineError.functionMissing
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "OverlayPipeline"
        descriptor.vertexFunction = vfn
        descriptor.fragmentFunction = ffn

        // Source-over straight-alpha blend: result = src.rgb * src.a +
        // dst.rgb * (1 - src.a). With `alpha=0` (blink-off phase) the
        // overlay disappears cleanly without re-encoding the grid pass.
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = pixelFormat
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .sourceAlpha
        color.sourceAlphaBlendFactor = .sourceAlpha
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    enum PipelineError: Error {
        case libraryUnavailable
        case functionMissing
    }

    /// Encode one overlay quad. Caller has already opened a render pass
    /// against the same color attachment used by the grid pass with
    /// `loadAction = .load` so the grid pass's pixels remain visible
    /// where the overlay is transparent.
    func encode(uniforms: OverlayUniforms, encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(pipelineState)
        var u = uniforms
        encoder.setVertexBytes(
            &u, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
        encoder.setFragmentBytes(
            &u, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}

/// CPU-driven blink phase. Pure function so the renderer's draw loop
/// stays trivially testable; called once per frame with the current
/// elapsed time and the configured period (500 ms per
/// spec/metal-renderer.md:105).
///
/// Returns 1.0 for the first half of each period (cursor visible), 0.0
/// for the second half (cursor hidden). Steady (non-blinking) cursors
/// pass `period <= 0` and get `1.0` regardless of elapsed time.
@inline(__always)
func blinkAlpha(elapsed: CFTimeInterval, period: CFTimeInterval) -> Float {
    guard period > 0 else { return 1.0 }
    let phase = (elapsed / period).truncatingRemainder(dividingBy: 2.0)
    return phase < 1.0 ? 1.0 : 0.0
}
