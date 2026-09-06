// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// SessionJournal — a durable, main-thread-independent record of what each
// terminal window was doing, so a relaunch can put it back.
//
// WHY THIS EXISTS (it is not a duplicate of WindowRestoration.swift):
// `NSWindowRestoration` owns window frames and tab grouping and stays the
// primary restore path. This is a second, independent record of the same
// working directory, plus the one thing saved state never carried: the
// command the window was running.
//
// What saved state gives you is opaque, coalesced on AppKit's schedule,
// and best-effort at SIGKILL — `invalidateRestorableState()` only marks a
// window dirty, so how much of a recent `cd` survives depends on when
// AppKit next decides to flush. This journal is built so that none of
// that timing is in the way:
//
//   - The registry holds only `windowID → shell pid`. Everything else is
//     read from the pid via `ProcessSnapshot`, so the sample + write loop
//     touches no AppKit state and runs entirely off the main thread —
//     nothing about the UI's condition can stall it.
//   - Writes are atomic and content-addressed (skipped when nothing
//     changed), so a 5s cadence costs no disk churn while idle.
//   - It is plain JSON in Application Support, so it can be inspected and
//     repaired by hand. The saved-state blobs cannot.
//
// NOT a claim this file makes: that macOS drops saved state when the
// bundle is re-signed. That was the original hypothesis and testing
// contradicted it — state written by an 0.4.9 ad-hoc build was restored
// fine by an 0.4.12 one.
//
// Restore reconciliation lives in AppDelegate/WindowRestoration: entries
// whose window AppKit already restored are used only to refresh cwd and
// command; unclaimed entries open a window themselves.

import Foundation
import os

/// One window's persisted state. `Codable` — the on-disk format is JSON so
/// it stays greppable and hand-fixable.
struct SessionJournalEntry: Codable, Equatable {
    var id: String
    var cwd: String
    var title: String
    var command: String
    var order: Int
    var tabGroupID: String
    var updatedAt: Double

    /// Everything except `updatedAt`. The sampler compares on this so a
    /// pure timestamp bump never triggers a disk write.
    fileprivate var content: String {
        "\(id)\u{1}\(cwd)\u{1}\(title)\u{1}\(command)\u{1}\(order)\u{1}\(tabGroupID)"
    }
}

final class SessionJournal {
    static let shared = SessionJournal()

    /// Journal format version. Bump only on a breaking schema change; the
    /// loader drops documents it does not recognise rather than guessing.
    static let formatVersion = 1

    /// Upper bound on restored windows. A runaway journal should not be
    /// able to spawn hundreds of PTYs at launch.
    static let maxEntries = 50

    /// Longest command we will persist (UTF-8 bytes).
    static let maxCommandBytes = 512

    private struct Document: Codable {
        var version: Int
        var updatedAt: Double
        var windows: [SessionJournalEntry]
    }

    private struct Registration {
        var pid: pid_t
        var order: Int
        var tabGroupID: String
        var title: String
    }

    /// Written from the main thread, read from `queue` — hence the lock.
    private let lock = NSLock()
    private var registry: [String: Registration] = [:]

    /// Most recent sample per window, so the main thread can read back the
    /// command without re-scanning the process table inside
    /// `encodeRestorableState`. Guarded by `lock` (written on `queue`).
    private var lastSampled: [String: SessionJournalEntry] = [:]

    /// Touched only on `queue`.
    private var lastWrittenContent: String = ""

    private let queue = DispatchQueue(
        label: "com.zenzai.SolidTerm.session-journal", qos: .utility)
    private var timer: DispatchSourceTimer?

    private init() {}

    // MARK: - Registry (main thread)

    /// Idempotent — called on every cwd change, which is the earliest point
    /// the shell pid is valid and also the cheapest place to keep `title`
    /// and tab ordering fresh.
    func register(
        windowID: String, pid: pid_t, order: Int, tabGroupID: String, title: String
    ) {
        guard !windowID.isEmpty, pid > 0 else { return }
        lock.lock()
        registry[windowID] = Registration(
            pid: pid, order: order, tabGroupID: tabGroupID, title: title)
        let count = registry.count
        lock.unlock()
        Self.log.debug("register \(windowID, privacy: .public) pid=\(pid) → \(count) live")
    }

    /// Drop a closed window so a later force-quit cannot resurrect it.
    /// Flushes straight away: the whole point is that the next event may be
    /// a SIGKILL.
    func unregister(windowID: String) {
        guard !windowID.isEmpty else { return }
        lock.lock()
        let existed = registry.removeValue(forKey: windowID) != nil
        let count = registry.count
        lock.unlock()
        Self.log.debug(
            "unregister \(windowID, privacy: .public) existed=\(existed) → \(count) live")
        if existed { flushNow() }
    }

    static let log = Logger(subsystem: "com.zenzai.SolidTerm", category: "journal")

    /// Test seam — clears the registry and the change-detection baseline so
    /// each test starts from a known state.
    func resetForTesting() {
        queue.sync { self.lastWrittenContent = "" }
        lock.lock()
        registry.removeAll()
        lastSampled.removeAll()
        lock.unlock()
    }

    /// Latest sample for a window, or nil before the first sample lands.
    /// Cheap + lock-guarded so `encodeRestorableState` can call it on the
    /// main thread.
    func lastEntry(forWindowID id: String) -> SessionJournalEntry? {
        lock.lock()
        defer { lock.unlock() }
        return lastSampled[id]
    }

    // MARK: - Sampling

    /// Start the background sampler. Safe to call more than once.
    func startSampling(interval: TimeInterval = 5) {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + interval, repeating: interval)
            t.setEventHandler { [weak self] in self?.sampleAndWriteIfChanged() }
            self.timer = t
            t.resume()
        }
    }

    /// Sample and write immediately. Async so callers on the main thread
    /// (resign-active, window close) never block on disk.
    func flushNow() {
        queue.async { [weak self] in self?.sampleAndWriteIfChanged() }
    }

    /// Synchronous flush for `applicationWillTerminate`, where returning
    /// before the write lands would defeat the purpose.
    func flushSynchronously() {
        queue.sync { self.sampleAndWriteIfChanged() }
    }

    private func sampleAndWriteIfChanged() {
        lock.lock()
        let regs = registry
        lock.unlock()

        var entries: [SessionJournalEntry] = []
        if !regs.isEmpty {
            let children = ProcessSnapshot.childMap()
            let now = Date().timeIntervalSince1970
            for (id, reg) in regs {
                // A shell whose cwd cannot be read is gone (or exiting);
                // dropping it keeps dead windows out of the next restore.
                guard let cwd = ProcessSnapshot.cwd(forPid: reg.pid), !cwd.isEmpty else {
                    continue
                }
                let raw = ProcessSnapshot.newestChild(of: reg.pid, in: children)
                    .flatMap { ProcessSnapshot.commandLine(pid: $0) }
                entries.append(
                    SessionJournalEntry(
                        id: id,
                        cwd: cwd,
                        title: reg.title,
                        command: Self.sanitizeCommand(raw),
                        order: reg.order,
                        tabGroupID: reg.tabGroupID,
                        updatedAt: now))
            }
        }
        entries.sort { ($0.order, $0.id) < ($1.order, $1.id) }

        lock.lock()
        lastSampled = Dictionary(
            entries.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        lock.unlock()

        let content = entries.map(\.content).joined(separator: "\u{2}")
        guard content != lastWrittenContent else { return }
        if write(entries) { lastWrittenContent = content }
    }

    @discardableResult
    private func write(_ entries: [SessionJournalEntry]) -> Bool {
        let doc = Document(
            version: Self.formatVersion,
            updatedAt: Date().timeIntervalSince1970,
            windows: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(doc), let url = Self.fileURL else {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            // `.atomic` writes to a temp file and renames, so a crash
            // mid-write can never leave a truncated journal behind.
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Load

    /// `~/Library/Application Support/SolidTerm/session-journal.json`.
    /// Kept out of the saved-state directory so the two records stay
    /// genuinely independent — and so this one is a file the user can read.
    static var fileURL: URL? {
        if let override = fileURLOverrideForTesting { return override }
        // Env override so a second instance (or a debug run) can be pointed
        // at its own journal instead of fighting over the real one.
        if let path = ProcessInfo.processInfo.environment["SOLIDTERM_JOURNAL_PATH"],
            !path.isEmpty
        {
            return URL(fileURLWithPath: path)
        }
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false)
        else { return nil }
        return
            base
            .appendingPathComponent("SolidTerm", isDirectory: true)
            .appendingPathComponent("session-journal.json")
    }

    /// Test seam — redirects reads and writes to a temp file so the suite
    /// exercises the real IO path (atomic write, decode, prune) without
    /// clobbering the user's actual journal.
    static var fileURLOverrideForTesting: URL?

    /// Read + prune the journal. Entries whose directory no longer exists
    /// are dropped (reusing `WindowRestorerSupport.resolveCwd`), and the
    /// result is capped at `maxEntries` most-recent, ordered for display.
    static func load() -> [SessionJournalEntry] {
        guard
            let url = fileURL,
            let data = try? Data(contentsOf: url),
            let doc = try? JSONDecoder().decode(Document.self, from: data),
            doc.version == formatVersion
        else { return [] }

        return prune(doc.windows)
    }

    /// Pure prune/cap/order pass, split out of `load()` so it is unit
    /// testable without touching the real Application Support directory.
    /// Drops entries with no id or a directory that no longer exists, keeps
    /// the `maxEntries` most recent, and returns them in restore order.
    static func prune(_ windows: [SessionJournalEntry]) -> [SessionJournalEntry] {
        let alive = windows.filter {
            !$0.id.isEmpty && WindowRestorerSupport.resolveCwd($0.cwd) != nil
        }
        let capped =
            alive
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maxEntries)
        return capped.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// Entries no restored window claimed, grouped back into their original
    /// tab groups and ordered for reopening.
    ///
    /// Pure so the reconciliation rule — never reopen a window AppKit
    /// already restored — can be tested without standing up windows.
    static func pendingGroups(
        from entries: [SessionJournalEntry], claimed: Set<String>
    ) -> [[SessionJournalEntry]] {
        let pending = entries.filter { !claimed.contains($0.id) }
        guard !pending.isEmpty else { return [] }
        return Dictionary(grouping: pending, by: \.tabGroupID)
            .values
            .map { $0.sorted { ($0.order, $0.id) < ($1.order, $1.id) } }
            .sorted {
                ($0.first?.order ?? 0, $0.first?.id ?? "")
                    < ($1.first?.order ?? 0, $1.first?.id ?? "")
            }
    }

    /// Launch-time snapshot, memoised. Window restoration asks per window,
    /// and AppDelegate asks again to find unclaimed entries — they must all
    /// see the same list, and re-reading once per window would also mean
    /// re-parsing the file N times.
    private static var cachedRestoreSnapshot: [SessionJournalEntry]?

    static func restoreSnapshot() -> [SessionJournalEntry] {
        if let cached = cachedRestoreSnapshot { return cached }
        let loaded = load()
        cachedRestoreSnapshot = loaded
        return loaded
    }

    /// Test seam — drops the memoised snapshot.
    static func resetRestoreSnapshotForTesting() {
        cachedRestoreSnapshot = nil
    }

    // MARK: - Command hygiene

    /// Normalise a command line into something safe to type back into a
    /// shell prompt, or `""` when it is not.
    ///
    /// The restore path feeds this straight to the PTY, so anything that
    /// could *execute* rather than merely appear at the prompt has to be
    /// rejected here. That means every C0/C1 control character — not just
    /// newline. A stray `\n` or `\r` would run the command; ESC could open
    /// a control sequence; and the paste path's `\e[201~` jail guard should
    /// never have to fire on our own data.
    ///
    /// Over-long commands are rejected outright rather than truncated: a
    /// half a command left on the prompt is worse than none, because it
    /// still looks runnable.
    static func sanitizeCommand(_ raw: String?) -> String {
        guard let raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.utf8.count <= maxCommandBytes else { return "" }
        for scalar in trimmed.unicodeScalars {
            // C0 (incl. \n, \r, ESC), DEL, and C1.
            if scalar.value < 0x20 || scalar.value == 0x7F
                || (scalar.value >= 0x80 && scalar.value <= 0x9F)
            {
                return ""
            }
        }
        return trimmed
    }
}
