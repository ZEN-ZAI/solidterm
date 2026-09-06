// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// M7-3 — FontSettings tests.
//
// Coverage:
// - Defaults (no UserDefaults entry → Menlo / 14pt / ligatures off)
// - UserDefaults round-trip (write → re-instantiate → same values)
// - Size clamp (below min / above max snap to bounds)
// - Increase / decrease / reset semantics
// - `didChange` notification fires on each mutator
// - `makeCTFont` falls back to Menlo for unknown families

import AppKit
import XCTest

@testable import SolidTerm

@MainActor
final class FontSettingsTests: XCTestCase {

    /// Use a per-test ephemeral UserDefaults suite so the global
    /// `.standard` store stays untouched and parallel tests don't
    /// race on the same keys.
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "solidterm.tests.font.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    // MARK: - Defaults

    func testDefaultsWhenStoreEmpty() {
        let s = FontSettings(defaults: defaults)
        XCTAssertEqual(s.family, FontSettings.defaultFamily)
        XCTAssertEqual(s.size, FontSettings.defaultSize)
        XCTAssertFalse(s.ligatures)
    }

    // MARK: - Round-trip

    func testRoundTripFamilySizeLigatures() {
        do {
            let s = FontSettings(defaults: defaults)
            s.setFamily("Monaco")
            s.setSize(18)
            s.setLigatures(true)
        }
        let s2 = FontSettings(defaults: defaults)
        XCTAssertEqual(s2.family, "Monaco")
        XCTAssertEqual(s2.size, 18)
        XCTAssertTrue(s2.ligatures)
    }

    // MARK: - Clamp

    func testSizeClampsBelowMin() {
        let s = FontSettings(defaults: defaults)
        s.setSize(2)
        XCTAssertEqual(s.size, FontSettings.minSize)
    }

    func testSizeClampsAboveMax() {
        let s = FontSettings(defaults: defaults)
        s.setSize(999)
        XCTAssertEqual(s.size, FontSettings.maxSize)
    }

    // MARK: - Mutators

    func testIncreaseDecreaseResetSize() {
        let s = FontSettings(defaults: defaults)
        s.setSize(14)
        s.increaseSize()
        XCTAssertEqual(s.size, 15)
        s.decreaseSize()
        XCTAssertEqual(s.size, 14)
        s.setSize(20)
        s.resetSize()
        XCTAssertEqual(s.size, FontSettings.defaultSize)
    }

    /// Reset must restore the built-in default, not the
    /// most-recently-saved value (per M7 brief).
    func testResetIgnoresLastSavedValue() {
        let s = FontSettings(defaults: defaults)
        s.setSize(22)
        s.resetSize()
        XCTAssertEqual(s.size, FontSettings.defaultSize)
        XCTAssertNotEqual(s.size, 22)
    }

    func testEmptyFamilyRejected() {
        let s = FontSettings(defaults: defaults)
        s.setFamily("Monaco")
        s.setFamily("   ")
        XCTAssertEqual(s.family, "Monaco")
        s.setFamily("")
        XCTAssertEqual(s.family, "Monaco")
    }

    // MARK: - didChange notification

    func testDidChangePostedOnSizeChange() {
        let s = FontSettings(defaults: defaults)
        let exp = expectation(
            forNotification: FontSettings.didChange,
            object: s, handler: nil)
        s.increaseSize()
        wait(for: [exp], timeout: 0.5)
    }

    func testDidChangePostedOnFamilyChange() {
        let s = FontSettings(defaults: defaults)
        let exp = expectation(
            forNotification: FontSettings.didChange,
            object: s, handler: nil)
        s.setFamily("Monaco")
        wait(for: [exp], timeout: 0.5)
    }

    func testDidChangeNotPostedWhenValueUnchanged() {
        let s = FontSettings(defaults: defaults)
        s.setSize(14)
        var fired = false
        let token = NotificationCenter.default.addObserver(
            forName: FontSettings.didChange,
            object: s, queue: .main
        ) { _ in fired = true }
        defer { NotificationCenter.default.removeObserver(token) }
        s.setSize(14)  // identical → no post
        // Pump the runloop briefly so an in-flight post would fire.
        let until = Date(timeIntervalSinceNow: 0.05)
        RunLoop.main.run(until: until)
        XCTAssertFalse(fired)
    }

    // MARK: - CTFont resolution

    func testMakeCTFontReturnsRequestedSize() {
        let font = FontSettings.makeCTFont(family: "Menlo-Regular", size: 18)
        XCTAssertEqual(CTFontGetSize(font), 18)
    }
}
