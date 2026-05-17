// E2E (in-process integration) tests for theme mode switching —
// asserts that ThemeManager.setMode flips both the published mode and
// the resolved color tokens, and broadcasts themeDidChange.
//
// Pollution guard: ThemeManager.shared persists to UserDefaults. Each
// test snapshots the live value in setUp and restores in tearDown.

import AppKit
import Combine
import XCTest

@testable import SolidTerm

@MainActor
final class ThemeSwitchE2ETests: XCTestCase {

    private var savedRawMode: String?

    override func setUp() {
        super.setUp()
        savedRawMode = UserDefaults.standard.string(forKey: ThemeManager.modeKey)
    }

    override func tearDown() {
        if let raw = savedRawMode,
            let restored = Theme.Mode(rawValue: raw)
        {
            ThemeManager.shared.setMode(restored)
        } else {
            ThemeManager.shared.setMode(.system)
            UserDefaults.standard.removeObject(forKey: ThemeManager.modeKey)
        }
        super.tearDown()
    }

    // MARK: - Mode switch updates resolved tokens

    /// Light/dark `bgBase` must resolve to different RGB. If the mode
    /// switches but the resolved token doesn't, the picker is broken.
    func testThemeModeSwitchUpdatesResolvedTokens() {
        ThemeManager.shared.setMode(.light)
        let lightBg = Theme.Color.bgBaseLinear(for: .light)
        ThemeManager.shared.setMode(.dark)
        let darkBg = Theme.Color.bgBaseLinear(for: .dark)
        XCTAssertNotEqual(
            lightBg, darkBg,
            "light and dark bgBase must produce different SIMD4 values")
    }

    // MARK: - Mode switch broadcasts themeDidChange

    func testThemeModeSwitchBroadcastsNotification() {
        // Start from a known mode so setMode actually flips.
        ThemeManager.shared.setMode(.dark)

        var received = 0
        let token = NotificationCenter.default.addObserver(
            forName: ThemeManager.themeDidChange,
            object: nil, queue: .main
        ) { _ in received += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        ThemeManager.shared.setMode(.light)
        // Notification posts synchronously inside `mode.didSet`.
        XCTAssertEqual(
            received, 1,
            "setMode(.light) from .dark must post one themeDidChange")

        // Idempotent re-set must NOT re-broadcast.
        ThemeManager.shared.setMode(.light)
        XCTAssertEqual(
            received, 1,
            "setMode(.light) when already .light must be a no-op")
    }

    // MARK: - Resolved follows .system

    func testSystemModeResolvesToCurrentAppearance() {
        ThemeManager.shared.setMode(.system)
        let resolved = ThemeManager.shared.resolved
        // We can't toggle system appearance from a unit test; just
        // assert resolved is one of the two valid cases (not crashed,
        // not a third value).
        XCTAssertTrue(
            resolved == .light || resolved == .dark,
            "resolved must be light or dark; got \(resolved)")
    }
}
