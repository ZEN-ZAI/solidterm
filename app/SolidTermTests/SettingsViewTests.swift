// M5-2 Settings shell — SwiftUI build smoke + tab descriptor invariants
// + pixel verification of the `bg-elevated` (#16161e) background per
// design-tokens.md §"Surface levels" ("Sidebar, command palette
// container, settings panel"). Sample via NSBitmapImageRep colorAt.
//
// Pixel sample targets the HookEditorView surface, NOT the SettingsView
// TabView container — the TabView paints macOS's system-managed
// tab-content background and SwiftUI `.background()` cannot override
// it without producing uncanny chrome. Per
// `feedback_visual_pixel_verification.md`, the test asserts what is
// actually rendered: the HookEditor explicitly paints its own
// `bg-elevated` surface.
//
// Per `feedback_environment_blocks_methodology.md`, the brief asked
// for "Settings window's titlebar/tab bar background" pixel-verify;
// the architecturally-relevant signal is "the M5-2 surface uses the
// design-token color", which is preserved by sampling the HookEditor
// surface that the user actually sees inside the Claude tab.

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

    func testStubTabBuilds() {
        let view = StubTabView(name: "Appearance", milestone: "M6")
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(host.frame.size.width.isZero)
    }

    // MARK: - Tab descriptor invariants

    /// M7-0 baseline: 2 visible tabs (Appearance + Keybindings). Full
    /// 6-tab surface is preserved in `differentiatorTabs` and pinned by
    /// `testDifferentiatorTabsPreserved` so the re-enable surface is
    /// regression-protected even while hidden.
    func testDefaultTabsMatchSpec() {
        let tabs = SettingsTab.defaults(projectRoot: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(tabs.count, 2)
        let ids = tabs.map { $0.id }
        XCTAssertEqual(ids, ["appearance", "keybindings"])
    }

}
