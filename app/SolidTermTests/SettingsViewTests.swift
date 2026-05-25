// Settings shell — SwiftUI build smoke + tab descriptor invariants.

import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import SolidTerm

@MainActor
final class SettingsViewTests: XCTestCase {

    // MARK: - Build smoke

    func testSettingsViewBuildsWithDefaultTabs() {
        let projectRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        let view = SettingsView(tabs: SettingsTab.defaults(projectRoot: projectRoot))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(host.frame.size.width.isZero)
    }

    // MARK: - Tab descriptor invariants

    /// SolidTerm ships two Settings tabs — Appearance + Keybindings.
    /// Pinned so adding/removing a tab is a deliberate decision.
    func testDefaultTabsMatchSpec() {
        let tabs = SettingsTab.defaults(projectRoot: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(tabs.count, 2)
        let ids = tabs.map { $0.id }
        XCTAssertEqual(ids, ["appearance", "keybindings"])
    }
}
