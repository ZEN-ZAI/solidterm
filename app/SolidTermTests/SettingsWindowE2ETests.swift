// E2E (in-process integration) tests for the Settings window —
// asserts ⌘, opens the shared window with all configured tabs.

import AppKit
import XCTest

@testable import SolidTerm

@MainActor
final class SettingsWindowE2ETests: XCTestCase {

    func testSettingsWindowOpensViaAppDelegate() {
        let delegate = AppDelegate()
        delegate.openSettingsWindow()
        defer { SettingsWindowController.shared.window?.close() }

        let window = SettingsWindowController.shared.window
        XCTAssertNotNil(window, "openSettingsWindow must materialize a window")
        XCTAssertTrue(
            window?.isVisible ?? false,
            "settings window must be visible after open")
    }

    func testSettingsWindowExposesAllConfiguredTabs() {
        let projectRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        let tabs = SettingsTab.defaults(projectRoot: projectRoot)
        XCTAssertEqual(tabs.count, 2,
            "SolidTerm exposes Appearance + Keybindings only")
        let ids = tabs.map(\.id)
        XCTAssertEqual(ids, ["appearance", "keybindings"])
    }

    func testReopenReusesSharedWindow() {
        let delegate = AppDelegate()
        delegate.openSettingsWindow()
        let firstWindow = SettingsWindowController.shared.window
        delegate.openSettingsWindow()
        let secondWindow = SettingsWindowController.shared.window
        defer { secondWindow?.close() }

        XCTAssertTrue(
            firstWindow === secondWindow,
            "SettingsWindowController.shared must be a singleton across reopens")
    }
}
