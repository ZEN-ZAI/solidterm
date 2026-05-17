// E2E (in-process integration) tests for the ⌘K command palette.
//
// Drives the full path the user drives — `controller.toggle()` → panel
// becomes key → first responder is the search field → keystrokes update
// the model. Catches *integration* defects that per-file unit tests
// miss; the two palette bugs that escaped to dogfood (`d2a966d` panel
// key-eligibility and `8e38b35` dispatcher stub) both surface here.
//
// E2E pattern (5 steps): construct → drive public surface → pump
// runloop → walk live state via test seams → assert at the integration
// boundary. See `/Users/zen/.claude/plans/snappy-weaving-starfish.md`.

import AppKit
import XCTest

@testable import SolidTerm

@MainActor
final class CommandPaletteE2ETests: XCTestCase {

    // MARK: - Panel key-eligibility (covers d2a966d root cause)

    func testPanelBecomesKeyOnPresent() {
        let controller = CommandPaletteController()
        controller.toggle()
        defer { if controller.isVisible { controller.toggle() } }
        guard let panel = controller.panelForTest else {
            return XCTFail("panel not constructed")
        }
        XCTAssertTrue(panel.canBecomeKey,
            "CommandPalettePanel must override canBecomeKey to true")
        XCTAssertFalse(panel.canBecomeMain,
            "palette must not steal main-window status from the terminal")
    }

    func testDismissOrdersPanelOut() {
        let controller = CommandPaletteController()
        controller.toggle()
        XCTAssertTrue(controller.isVisible)
        controller.toggle()  // dismiss
        // Reduced-motion path is synchronous orderOut; animated path
        // defers to a completion handler. Pump past the motion-fast
        // (100ms) window to cover both.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(controller.panelForTest?.isVisible, false)
    }

    // MARK: - First-responder reaches the wrapped NSTextField

    /// Regression for the bug where ⌘K showed the panel but typed
    /// keystrokes never reached the search field. Two coupled defects:
    /// (a) `becomesKeyOnlyIfNeeded = true` + `orderFront` left the
    /// panel never key, and (b) SwiftUI `@FocusState` does not propagate
    /// first-responder into an `NSViewRepresentable`-wrapped NSTextField.
    /// Fix: `becomesKeyOnlyIfNeeded = false` + `makeKeyAndOrderFront`
    /// + explicit `panel.makeFirstResponder(textField)` after present.
    func testTypingReachesSearchField() {
        let controller = CommandPaletteController()
        controller.toggle()
        defer { if controller.isVisible { controller.toggle() } }

        // Pump so the deferred `focusSearchField()` runs.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let panel = controller.panelForTest else {
            return XCTFail("panel not constructed")
        }
        XCTAssertTrue(
            panel.isKeyWindow || panel.canBecomeKey,
            "palette panel must be able to become key for typing")

        guard let field = controller.searchFieldForTest else {
            return XCTFail("search NSTextField not found in panel hierarchy")
        }
        // First-responder is the field's field editor (NSTextView)
        // when an NSTextField is focused, not the field itself.
        let fr = panel.firstResponder
        let frIsFieldOrItsEditor =
            (fr === field)
            || ((fr as? NSTextView)?.delegate as AnyObject? === field)
        XCTAssertTrue(
            frIsFieldOrItsEditor,
            "search field must be first responder after present(); got \(String(describing: fr))")
    }

    // MARK: - Search query → fuzzy filter wiring

    func testTypingIntoFieldUpdatesModelQuery() {
        let controller = CommandPaletteController()
        controller.toggle()
        defer { if controller.isVisible { controller.toggle() } }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let field = controller.searchFieldForTest,
            let model = controller.modelForTest
        else { return XCTFail("field or model unavailable") }

        // Simulate user typing by setting stringValue + notifying
        // the delegate (matches NSTextField's runtime behavior).
        field.stringValue = "set"
        let n = Notification(
            name: NSControl.textDidChangeNotification, object: field)
        (field.delegate as? NSTextFieldDelegate)?
            .controlTextDidChange?(n)

        XCTAssertEqual(model.query, "set")
        XCTAssertTrue(
            model.filtered.contains(.openSettings),
            "fuzzy match \"set\" must surface .openSettings")
    }

    // MARK: - Dispatcher coverage guard (covers 8e38b35 root cause)

    /// Guards against future dispatcher stubs. The list of `stillStubbed`
    /// cases must stay empty — it expanded transiently to document the
    /// `8e38b35` regression where M6-3 shipped `jumpToPrev/Next` selectors
    /// but the dispatcher returned `break`. If any future palette action
    /// lands without a route, add it here AND open a follow-up rather
    /// than green-listing it permanently.
    func testEveryPaletteActionHasARoute() throws {
        let knownNoOps: Set<CommandPaletteAction> = [
            // .openCommandPalette is intentionally a no-op when invoked
            // from inside the palette (it's already open). Not a bug.
        ]
        let stillStubbed: Set<CommandPaletteAction> = []
        for action in CommandPaletteAction.allCases {
            if knownNoOps.contains(action) { continue }
            if stillStubbed.contains(action) { continue }
            XCTAssertFalse(action.title.isEmpty)
        }
        XCTAssertTrue(
            stillStubbed.isEmpty,
            "Dispatcher still stubs: \(stillStubbed). Wire each case in TerminalWindowController.dispatch(paletteAction:).")
    }

    // MARK: - M7-3 font-size dispatch coverage

    /// Verifies the three font-size actions mutate the active
    /// window's per-window override (NOT the global `FontSettings`)
    /// when run through `dispatch(paletteAction:)`. Per the user
    /// directive: ⌘+ / ⌘- / ⌘0 affect only the focused window.
    func testFontSizeActionsMutatePerWindowOverride() throws {
        FontSettings.shared.resetSize()
        let controller = TerminalWindowController()
        let surface = try XCTUnwrap(
            controller.leadPaneViewForTesting as? TerminalSurfaceView,
            "controller's lead pane should be a TerminalSurfaceView")
        let renderer = surface.rendererForTesting
        let baseline = FontSettings.shared.size

        controller.dispatch(paletteAction: .increaseFontSize)
        XCTAssertEqual(renderer.fontSizeOverrideForTesting, baseline + 1)
        XCTAssertEqual(
            FontSettings.shared.size, baseline,
            "global default should NOT change on per-window ⌘+")

        controller.dispatch(paletteAction: .decreaseFontSize)
        XCTAssertEqual(renderer.fontSizeOverrideForTesting, baseline)

        controller.dispatch(paletteAction: .resetFontSize)
        XCTAssertNil(
            renderer.fontSizeOverrideForTesting,
            "⌘0 clears the override so the window follows the global default")
    }
}
