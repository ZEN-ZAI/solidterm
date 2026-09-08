// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Tests for NSWindowRestoration auto-restore (layout + cwd).

import AppKit
import XCTest

@testable import SolidTerm

@MainActor
final class WindowRestorationTests: XCTestCase {

    private var controllers: [TerminalWindowController] = []

    override func tearDown() {
        for c in controllers { c.window?.close() }
        controllers.removeAll()
        super.tearDown()
    }

    private func makeController(
        initialCwd: String? = nil, restoredTitle: String? = nil
    ) -> TerminalWindowController {
        let c = TerminalWindowController(initialCwd: initialCwd, restoredTitle: restoredTitle)
        controllers.append(c)
        return c
    }

    // MARK: - WindowRestorerSupport.resolveCwd (pure)

    func testResolveCwdKeepsExistingDirectory() {
        XCTAssertEqual(WindowRestorerSupport.resolveCwd("/tmp"), "/tmp")
    }

    func testResolveCwdRejectsMissingDirectory() {
        XCTAssertNil(WindowRestorerSupport.resolveCwd("/definitely/not/here/xyz123"))
    }

    func testResolveCwdRejectsEmptyAndNil() {
        XCTAssertNil(WindowRestorerSupport.resolveCwd(nil))
        XCTAssertNil(WindowRestorerSupport.resolveCwd(""))
    }

    func testResolveCwdRejectsRegularFile() {
        let path = NSTemporaryDirectory() + "solidterm-restore-\(getpid()).tmp"
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertNil(
            WindowRestorerSupport.resolveCwd(path),
            "a regular file is not a directory and must not be a spawn cwd")
    }

    // MARK: - RestoreSettings (default ON)

    func testRestoreSettingsDefaultsOnWhenUnset() {
        let key = RestoreSettings.enabledKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(RestoreSettings.enabled, "unset → ON")
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(RestoreSettings.enabled)
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(RestoreSettings.enabled)
    }

    // MARK: - Secure-coding round-trip of the restorable state

    func testRestorableStateCodingRoundTrips() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode("/Users/zen/proj" as NSString, forKey: RestoreCoderKeys.cwd)
        archiver.encode("Restored Title" as NSString, forKey: RestoreCoderKeys.titleOverride)
        archiver.encode("claude --resume x" as NSString, forKey: RestoreCoderKeys.command)
        archiver.finishEncoding()

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true
        XCTAssertEqual(
            unarchiver.decodeObject(of: NSString.self, forKey: RestoreCoderKeys.cwd) as String?,
            "/Users/zen/proj")
        XCTAssertEqual(
            unarchiver.decodeObject(of: NSString.self, forKey: RestoreCoderKeys.titleOverride)
                as String?,
            "Restored Title")
        XCTAssertEqual(
            unarchiver.decodeObject(of: NSString.self, forKey: RestoreCoderKeys.command)
                as String?,
            "claude --resume x")
    }

    // MARK: - Command pre-fill

    /// Run `body` with the pre-fill toggle forced to `enabled`, restoring
    /// whatever the user actually had afterwards.
    private func withPrefill(_ enabled: Bool, _ body: () -> Void) {
        let key = RestoreSettings.prefillCommandKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(enabled, forKey: key)
        body()
    }

    func testPrefillSettingDefaultsOnWhenUnset() {
        let key = RestoreSettings.prefillCommandKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(RestoreSettings.prefillCommandEnabled, "unset → ON")
    }

    func testResolveCommandReturnsSanitizedCommandWhenEnabled() {
        withPrefill(true) {
            XCTAssertEqual(
                WindowRestorerSupport.resolveCommand("  npm test  "), "npm test")
        }
    }

    func testResolveCommandReturnsNilWhenDisabled() {
        withPrefill(false) {
            XCTAssertNil(WindowRestorerSupport.resolveCommand("npm test"))
        }
    }

    /// Second gate: the journal is a plain JSON file on disk, so a command
    /// that was tampered with after being recorded must still be refused
    /// here — right before the bytes would reach the PTY.
    func testResolveCommandRejectsInjectedNewlineEvenWhenEnabled() {
        withPrefill(true) {
            XCTAssertNil(WindowRestorerSupport.resolveCommand("npm test\nrm -rf ~"))
            XCTAssertNil(WindowRestorerSupport.resolveCommand("ls \u{1B}[201~"))
        }
    }

    func testResolveCommandRejectsNilAndEmpty() {
        withPrefill(true) {
            XCTAssertNil(WindowRestorerSupport.resolveCommand(nil))
            XCTAssertNil(WindowRestorerSupport.resolveCommand(""))
        }
    }

    // MARK: - Window wiring

    func testWindowCarriesRestorationClassIdentifierAndTabbingId() throws {
        let w = try XCTUnwrap(makeController().window)
        let restorer = try XCTUnwrap(w.restorationClass)
        XCTAssertEqual(
            ObjectIdentifier(restorer), ObjectIdentifier(TerminalWindowRestorer.self),
            "restorationClass must be TerminalWindowRestorer")
        let id = try XCTUnwrap(w.identifier)
        XCTAssertTrue(
            id.rawValue.hasPrefix("SolidTermTerminal-"), "stable per-window identifier")
        XCTAssertEqual(w.tabbingIdentifier, "SolidTermTerminalTabs")
    }

    func testRestoredTitleAppliedAndDefaulted() throws {
        XCTAssertEqual(try XCTUnwrap(makeController().window).title, "SolidTerm")
        XCTAssertEqual(
            try XCTUnwrap(makeController(restoredTitle: "Restored X").window).title, "Restored X")
    }

    // MARK: - Deliberately closed windows

    /// Writes a journal listing `ids` and points the loader at it.
    private func withJournal(
        listing ids: [String], cwd: String = "/tmp", _ body: () throws -> Void
    ) rethrows {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solidterm-known-\(UUID().uuidString).json")
        let windows = ids.map {
            """
            {"id":"\($0)","cwd":"\(cwd)","title":"T","command":"",
             "order":0,"tabGroupID":"g","updatedAt":1}
            """
        }
        let doc = """
            {"version":1,"updatedAt":1,"windows":[\(windows.joined(separator: ","))]}
            """
        try? doc.write(to: url, atomically: true, encoding: .utf8)
        SessionJournal.fileURLOverrideForTesting = url
        SessionJournal.resetRestoreSnapshotForTesting()
        defer {
            SessionJournal.fileURLOverrideForTesting = nil
            SessionJournal.resetRestoreSnapshotForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        try body()
    }

    /// The bug this guards: AppKit keeps a saved-state record for a window
    /// the user closed on purpose, so restore would bring it back.
    func testKnewWindowRejectsIdTheJournalDropped() {
        withJournal(listing: ["w-live"]) {
            XCTAssertTrue(SessionJournal.knewWindow("w-live"))
            XCTAssertFalse(
                SessionJournal.knewWindow("w-closed"),
                "an id the journal no longer lists was closed deliberately")
        }
    }

    /// An entry pruned for a vanished cwd still means "this window was
    /// open" — it must restore (at $HOME), not be treated as closed.
    func testKnewWindowAcceptsEntryPrunedForMissingCwd() {
        withJournal(listing: ["w-gone-cwd"], cwd: "/definitely/not/here/xyz123") {
            XCTAssertTrue(SessionJournal.restoreSnapshot().isEmpty, "pruned out of the snapshot")
            XCTAssertTrue(
                SessionJournal.knewWindow("w-gone-cwd"),
                "a missing directory is not the same as a closed window")
        }
    }

    /// An empty journal is a statement, not a shrug: every window was
    /// closed before the app went away. Nineteen dead windows came back at
    /// once when this returned true.
    func testKnewWindowRejectsEverythingWhenJournalIsEmpty() {
        withJournal(listing: []) {
            XCTAssertFalse(
                SessionJournal.knewWindow("anything"),
                "a journal recording zero open windows must restore none of them")
        }
    }

    /// No journal at all (first launch after upgrade, or a lost file) is
    /// the only real no-opinion — AppKit's restore must not be suppressed.
    func testKnewWindowAcceptsEverythingWithoutAJournal() {
        SessionJournal.fileURLOverrideForTesting = URL(
            fileURLWithPath: "/definitely/not/here/journal.json")
        SessionJournal.resetRestoreSnapshotForTesting()
        defer {
            SessionJournal.fileURLOverrideForTesting = nil
            SessionJournal.resetRestoreSnapshotForTesting()
        }
        XCTAssertTrue(SessionJournal.knewWindow("anything"))
    }

    /// The other half of the fix: closing a window has to take it out of
    /// AppKit's saved state too, or the record just comes back next quit.
    func testDeliberateCloseMarksWindowNotRestorable() throws {
        let delegate = AppDelegate()
        let controller = makeController()
        delegate.adoptRestoredController(controller)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isRestorable, "windows are restorable while open")

        delegate.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: window))

        XCTAssertFalse(
            window.isRestorable,
            "a deliberately closed window must not be persisted by AppKit")
    }

    func testAdoptRestoredControllerSetsDelegateAndIsIdempotent() throws {
        let delegate = AppDelegate()
        let controller = makeController()
        delegate.adoptRestoredController(controller)
        XCTAssertTrue(
            controller.window?.delegate === delegate,
            "adopted controller's window delegate routes windowWillClose to AppDelegate")
        // Idempotent: a second adopt must not crash or change the delegate.
        delegate.adoptRestoredController(controller)
        XCTAssertTrue(controller.window?.delegate === delegate)
    }
}
