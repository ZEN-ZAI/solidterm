// E2E (in-process integration) tests for the ⌘F find-in-scrollback
// search panel.
//
// E2E pattern: construct → drive public surface → pump runloop → walk
// live state via test seams → assert at the integration boundary.

import AppKit
import XCTest

@testable import SolidTerm

@MainActor
final class SearchPanelE2ETests: XCTestCase {

    // MARK: - Panel key-eligibility

    func testPanelBecomesKeyOnPresent() {
        let controller = SearchPanelController()
        controller.toggle()
        defer { if controller.isVisible { controller.toggle() } }
        guard let panel = controller.panelForTest else {
            return XCTFail("panel not constructed")
        }
        XCTAssertTrue(panel.canBecomeKey,
            "SearchPanel must override canBecomeKey to true")
        XCTAssertFalse(panel.canBecomeMain,
            "search panel must not steal main-window status")
    }

    func testDismissOrdersPanelOut() {
        let controller = SearchPanelController()
        controller.toggle()
        XCTAssertTrue(controller.isVisible)
        controller.toggle()  // dismiss
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(controller.panelForTest?.isVisible, false)
    }

    /// Regression: panel shown but keystrokes never reach the
    /// wrapped NSTextField. Fix combines `canBecomeKey` override on
    /// the panel with a deferred `makeFirstResponder` after present.
    func testTypingReachesSearchField() {
        let controller = SearchPanelController()
        controller.toggle()
        defer { if controller.isVisible { controller.toggle() } }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let panel = controller.panelForTest else {
            return XCTFail("panel not constructed")
        }
        XCTAssertTrue(
            panel.isKeyWindow || panel.canBecomeKey,
            "search panel must be able to become key for typing")

        guard let field = controller.searchFieldForTest else {
            return XCTFail("search NSTextField not found in panel hierarchy")
        }
        let fr = panel.firstResponder
        let frIsFieldOrItsEditor =
            (fr === field)
            || ((fr as? NSTextView)?.delegate as AnyObject? === field)
        XCTAssertTrue(
            frIsFieldOrItsEditor,
            "search field must be first responder; got \(String(describing: fr))")
    }

    func testTypingIntoFieldUpdatesModelQuery() {
        let controller = SearchPanelController()
        controller.toggle()
        defer { if controller.isVisible { controller.toggle() } }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let field = controller.searchFieldForTest,
            let model = controller.modelForTest
        else { return XCTFail("field or model unavailable") }

        field.stringValue = "alpha"
        let n = Notification(
            name: NSControl.textDidChangeNotification, object: field)
        (field.delegate as? NSTextFieldDelegate)?
            .controlTextDidChange?(n)

        XCTAssertEqual(model.query, "alpha")
    }

    /// Regression for the 2026-05-19 dismiss/present race: pressing
    /// ⌘F a second time while the panel's dismiss fade-out animation
    /// was still in flight used to leave the panel ordered-out. Root
    /// cause: the stale `NSAnimationContext` completion handler ran
    /// AFTER `present()` had already re-shown the panel and called
    /// `orderOut` on the panel the user just asked to see again.
    /// Fix: the completion handler now checks `isDismissing` before
    /// touching the panel and bails when `present()` reset the flag.
    func testReopenDuringDismissKeepsPanelVisible() {
        let controller = SearchPanelController()
        // 1. Open.
        controller.toggle()
        XCTAssertTrue(
            controller.isVisible,
            "first toggle should have presented the panel")
        // 2. Start dismiss — the fade-out animator is now in flight.
        controller.toggle()
        // 3. Immediately re-open before the animator's completion
        //    handler can run (motion-fast is ~100 ms; we re-toggle
        //    on the same runloop tick, well inside that window).
        controller.toggle()
        // 4. Pump well past the original dismiss duration so any
        //    stale completion handler has had a chance to fire.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        // 5. Panel must still be on screen — that's what the user
        //    expects and what the pre-fix code violated.
        XCTAssertTrue(
            controller.isVisible,
            "re-opening during dismiss must keep the panel visible")
        XCTAssertEqual(
            controller.panelForTest?.isVisible, true,
            "underlying NSPanel must remain ordered-in")
        // Tear down cleanly.
        controller.toggle()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    func testCounterTextFormat() {
        let model = SearchPanelModel()
        XCTAssertEqual(model.counterText, "")
        model.query = "x"
        XCTAssertEqual(model.counterText, "0/0")
        model.matches = [
            SearchMatchSwift(line: 0, col: 0, len: 1),
            SearchMatchSwift(line: 1, col: 0, len: 1),
            SearchMatchSwift(line: 2, col: 0, len: 1),
        ]
        model.activeIndex = 0
        XCTAssertEqual(model.counterText, "1/3")
        model.activeIndex = 2
        XCTAssertEqual(model.counterText, "3/3")
    }
}

extension SearchPanelController {
    /// Test-only access to the lazily-built panel.
    var panelForTest: NSPanel? {
        Mirror(reflecting: self).children
            .first { $0.label == "panel" }?.value as? NSPanel
    }

    /// Test-only access to the wrapped model for query / state assertions.
    var modelForTest: SearchPanelModel? {
        Mirror(reflecting: self).children
            .first { $0.label == "model" }?.value as? SearchPanelModel
    }

    /// Test-only walker — finds the `SearchPanelTextField` inside the
    /// SwiftUI hosting hierarchy.
    var searchFieldForTest: SearchPanelTextField? {
        guard let root = panelForTest?.contentView else { return nil }
        func find(_ v: NSView) -> SearchPanelTextField? {
            if let f = v as? SearchPanelTextField { return f }
            for sub in v.subviews {
                if let f = find(sub) { return f }
            }
            return nil
        }
        return find(root)
    }
}
