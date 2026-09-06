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
