// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Tests for the durable session journal: command hygiene, prune/cap
// rules, restore reconciliation, and the KERN_PROCARGS2 parser.
//
// These cover the pure seams deliberately split out of the IO paths, so
// none of them touch the real Application Support directory or spawn a
// process.

import XCTest

@testable import SolidTerm

final class SessionJournalTests: XCTestCase {

    // MARK: - sanitizeCommand

    // This is the gate between a JSON file on disk and bytes written to a
    // PTY, so the rejection cases matter more than the happy path.

    func testSanitizeKeepsOrdinaryCommand() {
        XCTAssertEqual(
            SessionJournal.sanitizeCommand("claude --resume 845b1d61"),
            "claude --resume 845b1d61")
    }

    func testSanitizeTrimsSurroundingWhitespace() {
        XCTAssertEqual(SessionJournal.sanitizeCommand("  npm test  "), "npm test")
    }

    func testSanitizeRejectsNilAndEmpty() {
        XCTAssertEqual(SessionJournal.sanitizeCommand(nil), "")
        XCTAssertEqual(SessionJournal.sanitizeCommand(""), "")
        XCTAssertEqual(SessionJournal.sanitizeCommand("   "), "")
    }

    /// A newline would *run* the restored command instead of parking it on
    /// the prompt — the single most important rejection.
    func testSanitizeRejectsNewlineAndCarriageReturn() {
        XCTAssertEqual(SessionJournal.sanitizeCommand("rm -rf /\nyes"), "")
        XCTAssertEqual(SessionJournal.sanitizeCommand("deploy\rprod"), "")
    }

    /// ESC could open a control sequence once fed to the terminal.
    func testSanitizeRejectsEscapeAndControlCharacters() {
        XCTAssertEqual(SessionJournal.sanitizeCommand("ls \u{1B}[201~ evil"), "")
        XCTAssertEqual(SessionJournal.sanitizeCommand("ls \u{07}"), "")
        XCTAssertEqual(SessionJournal.sanitizeCommand("ls \u{7F}"), "")
        XCTAssertEqual(SessionJournal.sanitizeCommand("ls \u{9B}"), "")
    }

    /// Rejected, not truncated: half a command still looks runnable.
    func testSanitizeRejectsOverlongCommand() {
        let long = String(repeating: "a", count: SessionJournal.maxCommandBytes + 1)
        XCTAssertEqual(SessionJournal.sanitizeCommand(long), "")
        let atLimit = String(repeating: "a", count: SessionJournal.maxCommandBytes)
        XCTAssertEqual(SessionJournal.sanitizeCommand(atLimit), atLimit)
    }

    /// The limit is bytes, not characters — multibyte commands must not
    /// sneak past it.
    func testSanitizeCountsUTF8Bytes() {
        let thai = String(repeating: "ก", count: SessionJournal.maxCommandBytes)
        XCTAssertGreaterThan(thai.utf8.count, SessionJournal.maxCommandBytes)
        XCTAssertEqual(SessionJournal.sanitizeCommand(thai), "")
    }

    /// Whatever survives sanitising is fed to the PTY verbatim, so it must
    /// be impossible for a surviving payload to carry a line break.
    func testSanitizedOutputNeverContainsNewline() {
        for candidate in ["a\nb", "a\r\nb", "ok", "claude --resume x\n"] {
            let clean = SessionJournal.sanitizeCommand(candidate)
            XCTAssertFalse(clean.contains("\n"))
            XCTAssertFalse(clean.contains("\r"))
        }
    }

    // MARK: - Codable

    func testEntryRoundTripsThroughJSON() throws {
        let entry = SessionJournalEntry(
            id: "SolidTermTerminal-ABC", cwd: "/tmp", title: "onex-portal",
            command: "claude --resume x", order: 2, tabGroupID: "group-1",
            updatedAt: 1_755_400_000)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SessionJournalEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    // MARK: - prune

    /// Named `makeEntry`, not `entry` — `Darwin.entry` is a struct and the
    /// bare name resolves to it inside this module.
    private func makeEntry(
        id: String, cwd: String = "/tmp", order: Int = 0,
        group: String = "g", updatedAt: Double = 0, command: String = ""
    ) -> SessionJournalEntry {
        SessionJournalEntry(
            id: id, cwd: cwd, title: "", command: command, order: order,
            tabGroupID: group, updatedAt: updatedAt)
    }

    func testPruneDropsEntriesWhoseDirectoryIsGone() {
        let kept = makeEntry(id: "a", cwd: "/tmp")
        let gone = makeEntry(id: "b", cwd: "/definitely/not/here/xyz123")
        let result = SessionJournal.prune([kept, gone])
        XCTAssertEqual(result.map(\.id), ["a"])
    }

    func testPruneDropsEntriesWithEmptyID() {
        XCTAssertTrue(SessionJournal.prune([makeEntry(id: "")]).isEmpty)
    }

    func testPruneCapsAtMaxEntriesKeepingMostRecent() {
        let over = SessionJournal.maxEntries + 10
        let entries = (0..<over).map {
            makeEntry(id: "id-\($0)", order: $0, updatedAt: Double($0))
        }
        let result = SessionJournal.prune(entries)
        XCTAssertEqual(result.count, SessionJournal.maxEntries)
        // The 10 oldest (lowest updatedAt) are the ones dropped.
        XCTAssertFalse(result.contains { $0.id == "id-0" })
        XCTAssertTrue(result.contains { $0.id == "id-\(over - 1)" })
    }

    func testPruneReturnsRestoreOrder() {
        let result = SessionJournal.prune([
            makeEntry(id: "c", order: 2), makeEntry(id: "a", order: 0),
            makeEntry(id: "b", order: 1),
        ])
        XCTAssertEqual(result.map(\.id), ["a", "b", "c"])
    }

    // MARK: - pendingGroups (restore reconciliation)

    /// The core anti-duplicate rule: a window AppKit already restored must
    /// never be reopened from the journal.
    func testPendingGroupsSkipsClaimedIDs() {
        let entries = [
            makeEntry(id: "a", order: 0, group: "g1"),
            makeEntry(id: "b", order: 1, group: "g2"),
        ]
        let groups = SessionJournal.pendingGroups(from: entries, claimed: ["a"])
        XCTAssertEqual(groups.flatMap { $0 }.map(\.id), ["b"])
    }

    func testPendingGroupsEmptyWhenEverythingClaimed() {
        let entries = [makeEntry(id: "a"), makeEntry(id: "b")]
        XCTAssertTrue(
            SessionJournal.pendingGroups(from: entries, claimed: ["a", "b"]).isEmpty)
    }

    /// Tabs of one window share a tabGroupID and must come back as one
    /// group, in their recorded order.
    func testPendingGroupsRebuildsTabGroupsInOrder() {
        let entries = [
            makeEntry(id: "t2", order: 1, group: "g1"),
            makeEntry(id: "solo", order: 5, group: "g2"),
            makeEntry(id: "t1", order: 0, group: "g1"),
        ]
        let groups = SessionJournal.pendingGroups(from: entries, claimed: [])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].map(\.id), ["t1", "t2"])
        XCTAssertEqual(groups[1].map(\.id), ["solo"])
    }

    // MARK: - KERN_PROCARGS2 parsing

    private func makeArgsBlob(
        argc: Int32, execPath: String, padding: Int, args: [String], env: [String]
    ) -> [UInt8] {
        var blob: [UInt8] = []
        withUnsafeBytes(of: argc) { blob.append(contentsOf: $0) }
        blob.append(contentsOf: Array(execPath.utf8))
        blob.append(0)
        blob.append(contentsOf: [UInt8](repeating: 0, count: padding))
        for a in args {
            blob.append(contentsOf: Array(a.utf8))
            blob.append(0)
        }
        for e in env {
            blob.append(contentsOf: Array(e.utf8))
            blob.append(0)
        }
        return blob
    }

    func testParseProcArgs2ReadsArgvAndSkipsExecPath() {
        let blob = makeArgsBlob(
            argc: 2, execPath: "/bin/zsh", padding: 3, args: ["zsh", "-l"], env: [])
        XCTAssertEqual(ProcessSnapshot.parseProcArgs2(blob), "zsh -l")
    }

    /// The environment sits directly after argv in the same blob and can
    /// hold secrets; stopping at argc is what keeps it out of the journal.
    func testParseProcArgs2ExcludesEnvironment() {
        let blob = makeArgsBlob(
            argc: 1, execPath: "/bin/zsh", padding: 2, args: ["zsh"],
            env: ["AWS_SECRET_ACCESS_KEY=hunter2"])
        let parsed = ProcessSnapshot.parseProcArgs2(blob)
        XCTAssertEqual(parsed, "zsh")
        XCTAssertFalse(parsed?.contains("hunter2") ?? true)
    }

    func testParseProcArgs2HandlesMultiArgCommand() {
        let blob = makeArgsBlob(
            argc: 3, execPath: "/usr/local/bin/claude", padding: 1,
            args: ["claude", "--resume", "845b1d61"], env: [])
        XCTAssertEqual(ProcessSnapshot.parseProcArgs2(blob), "claude --resume 845b1d61")
    }

    func testParseProcArgs2HandlesNoPadding() {
        let blob = makeArgsBlob(
            argc: 1, execPath: "/bin/ls", padding: 0, args: ["ls"], env: [])
        XCTAssertEqual(ProcessSnapshot.parseProcArgs2(blob), "ls")
    }

    func testParseProcArgs2RejectsMalformedBlobs() {
        XCTAssertNil(ProcessSnapshot.parseProcArgs2([]))
        XCTAssertNil(ProcessSnapshot.parseProcArgs2([1, 2]))
        XCTAssertNil(
            ProcessSnapshot.parseProcArgs2(
                makeArgsBlob(
                    argc: 0, execPath: "/bin/zsh", padding: 1, args: [], env: [])))
    }

    // MARK: - Round trip through the real file

    // These drive the actual sampler + atomic write + load path against a
    // real pid (our own), redirected to a temp file. This is the seam the
    // GUI cannot be driven through deterministically, and it is where a
    // regression in "does a registered window actually get journalled"
    // would show up.

    private func withTempJournal(_ body: (URL) throws -> Void) rethrows {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solidterm-journal-\(getpid())-\(UUID().uuidString).json")
        SessionJournal.fileURLOverrideForTesting = url
        SessionJournal.shared.resetForTesting()
        defer {
            SessionJournal.shared.resetForTesting()
            SessionJournal.fileURLOverrideForTesting = nil
            try? FileManager.default.removeItem(at: url)
        }
        try body(url)
    }

    func testRegisteredProcessIsSampledAndWrittenToDisk() throws {
        try withTempJournal { url in
            SessionJournal.shared.register(
                windowID: "w-1", pid: getpid(), order: 0, tabGroupID: "g-1",
                title: "Test Window")
            SessionJournal.shared.flushSynchronously()

            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "flush must have written the journal")

            let entry = try XCTUnwrap(SessionJournal.shared.lastEntry(forWindowID: "w-1"))
            XCTAssertEqual(entry.id, "w-1")
            XCTAssertEqual(entry.title, "Test Window")
            XCTAssertEqual(entry.tabGroupID, "g-1")
            XCTAssertFalse(entry.cwd.isEmpty, "cwd must come back from proc_pidinfo")
        }
    }

    func testWrittenJournalLoadsBackWithSameContent() throws {
        try withTempJournal { _ in
            SessionJournal.shared.register(
                windowID: "w-load", pid: getpid(), order: 3, tabGroupID: "g-load",
                title: "Loadable")
            SessionJournal.shared.flushSynchronously()

            let loaded = SessionJournal.load()
            let entry = try XCTUnwrap(loaded.first { $0.id == "w-load" })
            XCTAssertEqual(entry.order, 3)
            XCTAssertEqual(entry.tabGroupID, "g-load")
            XCTAssertEqual(
                entry.cwd, SessionJournal.shared.lastEntry(forWindowID: "w-load")?.cwd)
        }
    }

    /// A deliberately closed window must not survive into the next launch.
    func testUnregisterRemovesEntryFromDisk() throws {
        try withTempJournal { _ in
            SessionJournal.shared.register(
                windowID: "w-gone", pid: getpid(), order: 0, tabGroupID: "g",
                title: "Doomed")
            SessionJournal.shared.flushSynchronously()
            XCTAssertFalse(SessionJournal.load().isEmpty)

            SessionJournal.shared.unregister(windowID: "w-gone")
            SessionJournal.shared.flushSynchronously()
            XCTAssertTrue(
                SessionJournal.load().isEmpty,
                "an unregistered window must not be restorable")
        }
    }

    /// A window whose shell has exited leaves no entry — dead windows must
    /// not be resurrected.
    func testDeadPidIsDroppedFromJournal() throws {
        try withTempJournal { _ in
            // pid 1 exists but is launchd (not ours); use a pid that is
            // almost certainly free instead.
            SessionJournal.shared.register(
                windowID: "w-dead", pid: 999_999, order: 0, tabGroupID: "g",
                title: "Dead")
            SessionJournal.shared.flushSynchronously()
            XCTAssertNil(SessionJournal.shared.lastEntry(forWindowID: "w-dead"))
            XCTAssertTrue(SessionJournal.load().isEmpty)
        }
    }

    // MARK: - Live process read (smoke)

    /// The parser is exercised above; this just proves the sysctl plumbing
    /// works against a real pid — our own.
    func testCommandLineForCurrentProcessIsReadable() throws {
        let command = try XCTUnwrap(ProcessSnapshot.commandLine(pid: getpid()))
        XCTAssertFalse(command.isEmpty)
    }

    func testChildMapFindsOurselfUnderOurParent() {
        let map = ProcessSnapshot.childMap()
        XCTAssertFalse(map.isEmpty, "process table read must not come back empty")
        let siblings = map[getppid()]?.map(\.pid) ?? []
        XCTAssertTrue(siblings.contains(getpid()))
    }

    func testCwdForCurrentProcessMatchesFileManager() {
        let cwd = ProcessSnapshot.cwd(forPid: getpid())
        XCTAssertNotNil(cwd)
    }
}

// MARK: - Registration against a live window (diagnostic)

@MainActor
final class SessionJournalRegistrationTests: XCTestCase {

    private var controllers: [TerminalWindowController] = []

    override func tearDown() {
        for c in controllers { c.window?.close() }
        controllers.removeAll()
        SessionJournal.shared.resetForTesting()
        SessionJournal.fileURLOverrideForTesting = nil
        super.tearDown()
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    /// Mirrors `AppDelegate.makeJournalController` / `TerminalWindowRestorer`:
    /// the controller is built first and re-keyed to its persisted
    /// identifier AFTERWARDS. Registration must land on the FINAL id.
    func testWindowRegistersUnderIdentifierAssignedAfterInit() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sj-reg-\(UUID().uuidString).json")
        SessionJournal.fileURLOverrideForTesting = url
        SessionJournal.shared.resetForTesting()
        defer { try? FileManager.default.removeItem(at: url) }

        let controller = TerminalWindowController(initialCwd: "/tmp")
        controllers.append(controller)
        controller.window?.identifier = NSUserInterfaceItemIdentifier("PERSISTED-ID-1")
        controller.showWindow(nil)

        pump(6)
        SessionJournal.shared.flushSynchronously()

        let entry = SessionJournal.shared.lastEntry(forWindowID: "PERSISTED-ID-1")
        XCTAssertNotNil(entry, "window must be journalled under its final identifier")
        // proc_pidinfo reports the resolved path, and /tmp is a symlink to
        // /private/tmp — compare resolved forms, not the spelling we passed.
        XCTAssertEqual(
            entry.map { URL(fileURLWithPath: $0.cwd).resolvingSymlinksInPath().path },
            URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path)
    }

    /// Two restored windows must BOTH end up in the journal.
    func testTwoRestoredWindowsBothRegister() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sj-reg2-\(UUID().uuidString).json")
        SessionJournal.fileURLOverrideForTesting = url
        SessionJournal.shared.resetForTesting()
        defer { try? FileManager.default.removeItem(at: url) }

        for (i, id) in ["RESCUE-A", "RESCUE-B"].enumerated() {
            let c = TerminalWindowController(initialCwd: i == 0 ? "/tmp" : "/usr")
            controllers.append(c)
            c.window?.identifier = NSUserInterfaceItemIdentifier(id)
            c.showWindow(nil)
        }

        pump(8)
        SessionJournal.shared.flushSynchronously()

        XCTAssertNotNil(SessionJournal.shared.lastEntry(forWindowID: "RESCUE-A"))
        XCTAssertNotNil(SessionJournal.shared.lastEntry(forWindowID: "RESCUE-B"))
        XCTAssertEqual(SessionJournal.load().count, 2)
    }
}
