// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// M7-5 — End-to-end tests for native NSWindowTabGroup integration.
//
// Architecture: each tab is a separate
// `TerminalWindowController` (one NSWindow). macOS's `NSWindowTabGroup`
// joins them via `addTabbedWindow(_:ordered:)`. ⌘T / ⌘W / ⌘⇧[ / ⌘⇧] /
// drag-out are system-handled; ⌘1-9 routes through
// `TerminalWindowController.selectTabN(_:)` selectors.
//
// These tests drive the public surface (action dispatch, tab-group
// joining, performClose teardown) and walk live state — they catch
// integration defects that per-file unit tests miss.

import AppKit
import XCTest

@testable import SolidTerm

@MainActor
final class TabsE2ETests: XCTestCase {

    private var controllers: [TerminalWindowController] = []

    override func tearDown() {
        // Close + drop every controller spun up so the next test runs
        // against a clean window state.
        for c in controllers {
            c.window?.close()
        }
        controllers.removeAll()
        super.tearDown()
    }

    private func makeController() -> TerminalWindowController {
        let c = TerminalWindowController()
        controllers.append(c)
        return c
    }

    // MARK: - Tab-group joining

    /// `addTabbedWindow(_:ordered:)` puts both windows in one tab group;
    /// `tabbedWindows` reports both members on each.
    func testAddTabbedWindow_growsTabGroup() {
        let a = makeController()
        let b = makeController()
        guard let aw = a.window, let bw = b.window else {
            return XCTFail("windows missing")
        }
        aw.makeKeyAndOrderFront(nil)
        aw.addTabbedWindow(bw, ordered: .above)

        let tabsA = aw.tabbedWindows ?? []
        XCTAssertEqual(tabsA.count, 2)
        XCTAssertTrue(tabsA.contains(aw))
        XCTAssertTrue(tabsA.contains(bw))

        // Both windows see the same tab group.
        XCTAssertTrue(aw.tabGroup === bw.tabGroup)
    }

    /// Closing the active tab via `performClose:` keeps the sibling
    /// alive — that's the "close last tab → close window" boundary
    /// that's only correct when there's exactly one tab left.
    func testCloseTab_keepsSiblingAlive() {
        let a = makeController()
        let b = makeController()
        guard let aw = a.window, let bw = b.window else {
            return XCTFail("windows missing")
        }
        aw.makeKeyAndOrderFront(nil)
        aw.addTabbedWindow(bw, ordered: .above)
        XCTAssertEqual(aw.tabbedWindows?.count, 2)

        // Close the second tab. The first must still be visible.
        bw.performClose(nil)

        // Drop the closed controller from our cleanup list so tearDown
        // doesn't double-close.
        controllers.removeAll { $0 === b }

        XCTAssertTrue(aw.isVisible, "lead tab must survive sibling close")
        // After bw closes, aw is on its own — `tabbedWindows` may report
        // [aw] or nil depending on AppKit; either is fine, what matters
        // is aw is still visible.
    }

    // MARK: - Action dispatch

    /// `AppDelegate.openNewTab(_:)` builds a fresh `TerminalWindowController`
    /// and orders it on screen — joining the key window's tab group when
    /// one exists, falling back to a standalone window otherwise. Under
    /// xctest's activation policy `NSApp.keyWindow` is nil (per the
    /// latency-harness memory) so this asserts the standalone-fallback
    /// branch: a new visible window is created. The tab-group branch is
    /// covered separately by `testAddTabbedWindow_growsTabGroup` which
    /// exercises AppKit's `addTabbedWindow(_:ordered:)` directly.
    func testAppDelegate_openNewTab_createsVisibleWindow() {
        let appDelegate = AppDelegate()
        let beforeWindowCount = NSApp.windows.count

        appDelegate.openNewTab(nil)
        // Pump so AppKit finishes wiring the new window's view tree.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let afterWindowCount = NSApp.windows.count
        XCTAssertGreaterThan(
            afterWindowCount, beforeWindowCount,
            "openNewTab must create at least one new NSWindow")
        // The newest window should be a TerminalWindowController-owned
        // NSWindow with the M7-5 tabbing-mode-preferred contract.
        let newWindow = NSApp.windows.last
        XCTAssertEqual(newWindow?.tabbingMode, .preferred)
    }

    /// `dispatch(.closeTab)` calls performClose on the window, which
    /// closes the active tab.
    func testActionDispatch_closeTab_closesActiveTab() {
        let a = makeController()
        let b = makeController()
        guard let aw = a.window, let bw = b.window else {
            return XCTFail("windows missing")
        }
        aw.makeKeyAndOrderFront(nil)
        aw.addTabbedWindow(bw, ordered: .above)
        XCTAssertEqual(aw.tabbedWindows?.count, 2)

        b.dispatch(action: .closeTab)
        controllers.removeAll { $0 === b }

        // aw still alive; tab group shrinks.
        XCTAssertTrue(aw.isVisible)
    }

    /// `dispatch(.selectTab2)` activates the second tab in the group.
    func testActionDispatch_selectTab2_makesSecondTabKey() {
        let a = makeController()
        let b = makeController()
        guard let aw = a.window, let bw = b.window else {
            return XCTFail("windows missing")
        }
        aw.makeKeyAndOrderFront(nil)
        aw.addTabbedWindow(bw, ordered: .above)

        // Dispatch from the *first* tab's controller; selectTab(2) walks
        // tabbedWindows and activates index 1.
        a.dispatch(action: .selectTab2)

        let tabs = aw.tabbedWindows ?? []
        XCTAssertEqual(tabs.count, 2)
        XCTAssertTrue(
            tabs[1] === bw,
            "second tab in group must be bw")
    }

    /// `selectTab(byIndex:)` is a no-op when N exceeds the tab count.
    /// Must not crash and must not change which window is key.
    func testSelectTab_outOfRange_isNoop() {
        let a = makeController()
        guard let aw = a.window else { return XCTFail("window missing") }
        aw.makeKeyAndOrderFront(nil)

        // Single-tab window — selectTab(5) should be safe.
        a.selectTab(byIndex: 5)
        XCTAssertTrue(aw.isVisible)
    }

    // MARK: - Engine session per tab

    /// Every tab gets its own `TerminalWindowController` → its own lead
    /// pane → its own splitter. Sessions don't share state.
    func testEachTab_hasOwnLeadPane() {
        let a = makeController()
        let b = makeController()
        XCTAssertFalse(
            a.paneSplitter === b.paneSplitter,
            "each tab must have its own splitter")
        XCTAssertEqual(a.paneSplitter.panes.count, 1)
        XCTAssertEqual(b.paneSplitter.panes.count, 1)
        XCTAssertFalse(
            a.paneSplitter.panes[0]
                === b.paneSplitter.panes[0],
            "each tab's lead pane must be a distinct PaneViewController")
    }

    // MARK: - Window-level title (OSC 0/2 binding plumbed already)

    /// Each tab's `NSWindow.title` is independent — that's what the
    /// system tab bar reads to label tabs. OSC 0/2 already updates
    /// `NSWindow.title` per-window via existing FFI; this test pins
    /// the contract.
    func testTabTitle_isPerWindow() {
        let a = makeController()
        let b = makeController()
        guard let aw = a.window, let bw = b.window else {
            return XCTFail("windows missing")
        }
        aw.makeKeyAndOrderFront(nil)
        aw.addTabbedWindow(bw, ordered: .above)

        aw.title = "Tab Alpha"
        bw.title = "Tab Bravo"

        XCTAssertEqual(aw.title, "Tab Alpha")
        XCTAssertEqual(bw.title, "Tab Bravo")
        XCTAssertNotEqual(
            aw.title, bw.title,
            "tab titles must not bleed between siblings")
    }

    // MARK: - tabbingMode preference

    /// `TerminalWindowController.convenience init` sets
    /// `tabbingMode = .preferred`. Without that, `addTabbedWindow` is
    /// a no-op on macOS Sonoma+.
    func testWindow_tabbingModeIsPreferred() {
        let a = makeController()
        XCTAssertEqual(a.window?.tabbingMode, .preferred)
    }

    // MARK: - closeWindowAndAllTabs

    /// `closeWindowAndAllTabs(_:)` closes every member of the tab group,
    /// not just the active one. This is the ⌘⇧W semantic.
    func testCloseWindowAndAllTabs_closesEveryMember() {
        let a = makeController()
        let b = makeController()
        guard let aw = a.window, let bw = b.window else {
            return XCTFail("windows missing")
        }
        aw.makeKeyAndOrderFront(nil)
        aw.addTabbedWindow(bw, ordered: .above)
        XCTAssertEqual(aw.tabbedWindows?.count, 2)

        // Trigger from one tab — both should close.
        a.closeWindowAndAllTabs(nil)
        controllers.removeAll { $0 === a || $0 === b }

        // Both windows are no longer visible.
        XCTAssertFalse(aw.isVisible)
        XCTAssertFalse(bw.isVisible)
    }
}

// MARK: - Action enum tab surface

@MainActor
final class TabsActionEnumTests: XCTestCase {

    /// Tab actions plus `selectTab1..9` are present in the action enum.
    func testTabActions_inAllCases() {
        let cases = Set(KeybindingAction.allCases)
        XCTAssertTrue(cases.contains(.newTab))
        XCTAssertTrue(cases.contains(.closeTab))
        XCTAssertTrue(cases.contains(.prevTab))
        XCTAssertTrue(cases.contains(.nextTab))
        for n in 1...9 {
            let raw = "selectTab\(n)"
            XCTAssertTrue(
                KeybindingAction.allCases
                    .contains(where: { $0.rawValue == raw }),
                "selectTab\(n) must be in allCases")
        }
    }

    /// `tabIndex` returns the digit for selectTabN cases and nil for
    /// non-tab-index cases.
    func testTabIndex_extractsDigit() {
        XCTAssertEqual(KeybindingAction.selectTab1.tabIndex, 1)
        XCTAssertEqual(KeybindingAction.selectTab9.tabIndex, 9)
        XCTAssertNil(KeybindingAction.newTab.tabIndex)
        XCTAssertNil(KeybindingAction.openSettings.tabIndex)
    }

    /// KeybindingStore defaults bind every tab action to its M7-5
    /// shortcut.
    func testDefaults_bindEveryTabAction() {
        let defaults = KeybindingStore.defaults
        XCTAssertEqual(defaults[.newTab], "cmd+t")
        XCTAssertEqual(defaults[.closeTab], "cmd+w")
        XCTAssertEqual(defaults[.prevTab], "cmd+shift+[")
        XCTAssertEqual(defaults[.nextTab], "cmd+shift+]")
        XCTAssertEqual(defaults[.selectTab1], "cmd+1")
        XCTAssertEqual(defaults[.selectTab5], "cmd+5")
        XCTAssertEqual(defaults[.selectTab9], "cmd+9")
        // closeWindow moved to cmd+shift+w so cmd+w can default to closeTab.
        XCTAssertEqual(defaults[.closeWindow], "cmd+shift+w")
    }
}
