// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// The MSL pipeline — confirms the
// pipeline state constructs cleanly from the bundled `default.metallib`
// and that the encode method runs without raising a Metal validation
// error against an offscreen render target. Pixel correctness is
// verified visually when MetalRenderer wires the pipeline (commit 4).

import CoreText
import Metal
import XCTest

@testable import SolidTerm

final class CellPipelineTests: XCTestCase {

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
    }

    override func tearDown() {
        queue = nil
        device = nil
    }

    func testPipelineStateConstructs() throws {
        let pipeline = try CellPipeline(device: device, pixelFormat: .bgra8Unorm_srgb)
        XCTAssertNotNil(pipeline.pipelineState)
    }

    func testEncodeDoesNotRaise() throws {
        let pipeline = try CellPipeline(device: device, pixelFormat: .bgra8Unorm_srgb)
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, 14, nil)
        let atlas = try GlyphAtlas(device: device, font: font, contentsScale: 2.0)
        let entry = try atlas.entry(for: Unicode.Scalar("A"), commandQueue: queue)

        // Offscreen target so we don't need a layer / drawable.
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: 256, height: 128, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: texDesc))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        let draw = CellDraw(
            cellCol: 0,
            cellRow: 0,
            entry: entry,
            fgColorLinear: SIMD4<Float>(1, 1, 1, 1),
            bgColorLinear: SIMD4<Float>(0, 0, 0, 1))
        pipeline.encode(
            draw,
            atlas: atlas,
            drawableSize: CGSize(width: 256, height: 128),
            encoder: encoder)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        XCTAssertNil(buffer.error, "expected encode to complete without Metal validation errors")
    }
}
