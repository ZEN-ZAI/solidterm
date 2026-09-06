// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Shared offscreen render + readback harness for the Metal pixel tests.
//
// Renders into a private-storage `.rgba8Unorm` target, blits it to a
// shared-storage twin and hands back the CPU-visible RGBA bytes. The
// non-sRGB format is load-bearing: the linear colours the shaders write
// read back as the same byte values, with no encode-on-store transform
// to reason about.
//
// Extracted from the two hand-rolled copies that had grown in
// `OverlayPipelineTests.testCursorShapesRenderExpectedGeometry` and
// `GridCursorReverseVideoTests.renderGrid`.

import Metal
import XCTest

/// One offscreen `.rgba8Unorm` render target plus its readback texture,
/// reusable across renders — every `render` call clears the target first.
struct MetalOffscreenHarness {

    let widthPx: Int
    let heightPx: Int

    private let queue: MTLCommandQueue
    private let clearColor: MTLClearColor
    private let renderTarget: MTLTexture
    private let readback: MTLTexture

    init(device: MTLDevice, widthPx: Int, heightPx: Int, clear: MTLClearColor) throws {
        self.widthPx = widthPx
        self.heightPx = heightPx
        clearColor = clear
        queue = try XCTUnwrap(device.makeCommandQueue())

        let renderDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: widthPx, height: heightPx, mipmapped: false)
        renderDesc.usage = [.renderTarget, .shaderRead]
        renderDesc.storageMode = .private
        renderTarget = try XCTUnwrap(device.makeTexture(descriptor: renderDesc))

        let readDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: widthPx, height: heightPx, mipmapped: false)
        readDesc.usage = [.shaderRead]
        readDesc.storageMode = .shared
        readback = try XCTUnwrap(device.makeTexture(descriptor: readDesc))
    }

    /// Clear the target, run `body` against a render encoder bound to it,
    /// blit to the readback texture and return the pixels the GPU wrote.
    func render(_ body: (MTLRenderCommandEncoder) throws -> Void) throws -> PixelBuffer {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = renderTarget
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor

        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        // End the encoder even when `body` throws: Metal traps on a command
        // buffer that still holds an open encoder.
        do {
            try body(encoder)
        } catch {
            encoder.endEncoding()
            throw error
        }
        encoder.endEncoding()

        // Blit to the shared-storage twin so the GPU work flushes to a
        // texture the CPU can read.
        let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
        blit.copy(
            from: renderTarget,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: widthPx, height: heightPx, depth: 1),
            to: readback,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)

        var bytes = [UInt8](repeating: 0, count: widthPx * heightPx * 4)
        bytes.withUnsafeMutableBufferPointer { ptr in
            readback.getBytes(
                ptr.baseAddress!,
                bytesPerRow: widthPx * 4,
                from: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: widthPx, height: heightPx, depth: 1)),
                mipmapLevel: 0)
        }
        return PixelBuffer(width: widthPx, height: heightPx, bytes: bytes)
    }
}

/// RGBA8 pixels read back from an offscreen render, addressed in pixels
/// from the top-left of the target.
struct PixelBuffer {

    let width: Int
    let height: Int
    /// Row-major RGBA bytes, `width * height * 4` long.
    let bytes: [UInt8]

    /// The four channel bytes at (`x`, `y`).
    func rgba(x: Int, y: Int) -> SIMD4<UInt8> {
        let i = (y * width + x) * 4
        return SIMD4<UInt8>(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }

    /// True when R, G and B at (`x`, `y`) are each within `tolerance` of
    /// `expected`. Alpha is not compared: the targets clear to alpha 1 and
    /// none of the passes under test write a meaningful alpha.
    func matchesColor(x: Int, y: Int, _ expected: SIMD3<UInt8>, tolerance: UInt8) -> Bool {
        let p = rgba(x: x, y: y)
        return Self.within(p.x, expected.x, tolerance)
            && Self.within(p.y, expected.y, tolerance)
            && Self.within(p.z, expected.z, tolerance)
    }

    /// `matchesColor` as an assertion, reporting each channel that missed.
    func assertCellColor(
        x: Int, y: Int, _ expected: SIMD3<UInt8>, tolerance: UInt8, _ label: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        let p = rgba(x: x, y: y)
        let channels = ["R", "G", "B"]
        for c in 0..<3 {
            XCTAssertTrue(
                Self.within(p[c], expected[c], tolerance),
                "\(label): \(channels[c]) = \(p[c]), expected \(expected[c]) ±\(tolerance)",
                file: file, line: line)
        }
    }

    /// Channel distance, computed without UInt8 wraparound.
    private static func within(_ actual: UInt8, _ expected: UInt8, _ tolerance: UInt8) -> Bool {
        let delta = actual > expected ? actual - expected : expected - actual
        return delta <= tolerance
    }
}
