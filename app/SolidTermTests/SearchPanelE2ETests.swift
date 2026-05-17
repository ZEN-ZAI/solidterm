// E2E (in-process integration) tests for the M7-2 ⌘F find-in-scrollback
// search panel. Mirrors the regression coverage pattern in
// `CommandPaletteE2ETests` (the two `d2a966d` / `8e38b35` panel bugs).
//
// E2E pattern: construct → drive public surface → pump runloop → walk
// live state via test seams → assert at the integration boundary.

import AppKit
import XCTest

@testable import SolidTerm

@MainActor
final class SearchPanelE2ETests: XCTestCase {

    // MARK: - Panel key-eligibility (mirrors CommandPalette d2a966d)

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

    /// Regression for the `d2a966d`-class bug: panel shown but
    /// keystrokes never reach the wrapped NSTextField. Same fix
    /// (canBecomeKey + makeFirstResponder after present) applies here.
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
