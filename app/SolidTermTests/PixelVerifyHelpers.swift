// M5.5-5: shared pixel-verify helpers extracted from
// `GutterViewTests` + `BlockOverlayManagerTests`. Both files run the
// same off-screen `NSHostingView.cacheDisplay(in:to:)` → bitmap-rep →
// sample → assert pattern per `feedback_environment_blocks_methodology`
// (screen-record perm blocked). Centralizing the helper keeps
// per-channel byte tolerance and Retina-scale derivation in one place.

import AppKit
import SwiftUI
import XCTest

@testable import SolidTerm

enum PixelVerify {
    /// Render an `NSHostingView` off-screen and return the bitmap rep.
    /// Caller is responsible for the host's frame + layout pass.
    @MainActor
    static func render<V: View>(
        _ host: NSHostingView<V>,
        file: StaticString = #file, line: UInt = #line
    ) throws -> NSBitmapImageRep {
        guard let rep = host.bitmapImageRepForCachingDisplay(
            in: host.bounds) else {
            XCTFail("bitmapImageRepForCachingDisplay nil",
                file: file, line: line)
            throw NSError(
                domain: "PixelVerify", code: 1, userInfo: nil)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Derive (xScale, yScale) from a rendered rep. Bitmap reps land
    /// at the device's backing scale (Retina 2× in test harness);
    /// callers convert pt → px via these multipliers.
    static func scale(
        _ rep: NSBitmapImageRep, hostBounds: NSRect
    ) -> (xScale: Double, yScale: Double) {
        (
            xScale: Double(rep.pixelsWide) / Double(hostBounds.width),
            yScale: Double(rep.pixelsHigh) / Double(hostBounds.height)
        )
    }

    /// Sample a pixel and assert its sRGB byte values match the
    /// expected `(r, g, b)` within ±3 channel tolerance — accommodates
    /// sub-pixel SwiftUI compositing rounding without being lax enough
    /// to miss a real drift (e.g. wrong token, wrong space).
    @MainActor
    static func assertHex(
        _ rep: NSBitmapImageRep, x: Int, y: Int,
        expected: (Int, Int, Int), label: String,
        file: StaticString = #file, line: UInt = #line
    ) throws {
        guard let color = rep.colorAt(x: x, y: y),
            let srgb = color.usingColorSpace(.sRGB) else {
            XCTFail("colorAt nil at \(label)",
                file: file, line: line)
            return
        }
        let r = Int(round(srgb.redComponent * 255))
        let g = Int(round(srgb.greenComponent * 255))
        let b = Int(round(srgb.blueComponent * 255))
        XCTAssertEqual(r, expected.0, accuracy: 3,
            "\(label) R", file: file, line: line)
        XCTAssertEqual(g, expected.1, accuracy: 3,
            "\(label) G", file: file, line: line)
        XCTAssertEqual(b, expected.2, accuracy: 3,
            "\(label) B", file: file, line: line)
    }

    /// Sample a pixel and assert it's transparent (alpha ≈ 0).
    /// Used by the M5.5 separation-guarantee tests: the gutter
    /// background lives in the metal-clear behind the SwiftUI host,
    /// so SwiftUI-side samples outside any stripe band must read
    /// alpha=0.
    @MainActor
    static func assertTransparent(
        _ rep: NSBitmapImageRep, x: Int, y: Int, label: String,
        file: StaticString = #file, line: UInt = #line
    ) {
        guard let color = rep.colorAt(x: x, y: y) else {
            XCTFail("colorAt nil at \(label)", file: file, line: line)
            return
        }
        XCTAssertEqual(
            color.alphaComponent, 0, accuracy: 0.05,
            "\(label) expected transparent",
            file: file, line: line)
    }
}
