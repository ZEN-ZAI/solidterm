// Pins the main-menu self-heal: SwiftUI's hosting views (find bar /
// switcher) intermittently strip the File/Edit submenus out of
// NSApp.mainMenu, killing every menu shortcut. AppDelegate.applicationDidUpdate
// detects the missing File menu and re-installs the app menu.

import AppKit
import XCTest

@testable import SolidTerm

@MainActor
final class AppMenuSelfHealTests: XCTestCase {

    private var savedMenu: NSMenu?

    override func setUp() {
        super.setUp()
        savedMenu = NSApp.mainMenu
    }

    override func tearDown() {
        NSApp.mainMenu = savedMenu
        super.tearDown()
    }

    func testApplicationDidUpdateRestoresStrippedMenu() {
        AppMenu.install()
        XCTAssertTrue(
            NSApp.mainMenu?.items.contains { $0.submenu?.title == "File" } ?? false,
            "precondition: a freshly installed menu has a File submenu")

        // Simulate the AppKit/SwiftUI clobber: drop File + Edit in place.
        if let menu = NSApp.mainMenu {
            for item in menu.items
            where item.submenu?.title == "File" || item.submenu?.title == "Edit" {
                menu.removeItem(item)
            }
        }
        XCTAssertFalse(
            NSApp.mainMenu?.items.contains { $0.submenu?.title == "File" } ?? true,
            "File menu should be gone after the simulated clobber")

        AppDelegate().applicationDidUpdate(Notification(name: NSApplication.didUpdateNotification))

        XCTAssertTrue(
            NSApp.mainMenu?.items.contains { $0.submenu?.title == "File" } ?? false,
            "self-heal must re-install the File menu")
        XCTAssertTrue(
            NSApp.mainMenu?.items.contains { $0.submenu?.title == "Edit" } ?? false,
            "self-heal must re-install the Edit menu")
    }

    func testApplicationDidUpdateLeavesIntactMenuAlone() {
        AppMenu.install()
        let before = NSApp.mainMenu
        AppDelegate().applicationDidUpdate(Notification(name: NSApplication.didUpdateNotification))
        XCTAssertTrue(
            NSApp.mainMenu === before,
            "an intact menu must not be reinstalled (no churn when nothing is wrong)")
    }
}
