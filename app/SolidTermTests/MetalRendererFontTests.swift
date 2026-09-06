// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// M7-3 — MetalRenderer font-observer wiring tests.
//
// Verifies the `FontSettings.didChange` → `atlasDirty` plumbing
// without standing up a live `CAMetalLayer` (needs a window). The
// renderer subscribes via `installFontObserverForTesting`, the test
// posts a font change, and the dirty flag is asserted.

import Metal
import XCTest

@testable import SolidTerm

@MainActor
final class MetalRendererFontTests: XCTestCase {

    func testAtlasDirtyFlipsOnFontSettingsChange() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = MetalRenderer(device: device)
        XCTAssertFalse(
            renderer.atlasDirty,
            "atlasDirty should start false")

        renderer.installFontObserverForTesting()
        FontSettings.shared.increaseSize()
        // The notification post is sync; observer block is on the
        // main queue, which we're already on. A short runloop pump
        // covers any deferred dispatch.
        let until = Date(timeIntervalSinceNow: 0.05)
        RunLoop.main.run(until: until)

        XCTAssertTrue(
            renderer.atlasDirty,
            "FontSettings.didChange must mark the atlas dirty")

        // Restore default so other tests don't observe a pumped-up
        // size. (FontSettings.shared is process-wide.)
        FontSettings.shared.resetSize()
    }
}
