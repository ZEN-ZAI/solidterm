// Window title + working-directory tracking for `MetalRenderer`, split
// out of the single-file renderer by method cluster: the per-frame OSC 0/2
// title drain, the OSC 7 cwd drain and its `proc_pidinfo` fallback poll.
// Stored properties live in MetalRenderer.swift because extensions cannot
// declare them.

import AppKit
import Darwin
import QuartzCore

extension MetalRenderer {
    /// 4.8: drain the engine's pending title-changed events and
    /// forward the latest to the host window. Called once per frame
    /// from `draw(update:)`. Empty-string sentinel = no event this
    /// tick → skip; otherwise set `window.title`. The display-link
    /// callback already runs on the main thread (per
    /// `CAMetalDisplayLink.add(to: .main, ...)`) so the AppKit
    /// `setTitle` call is safe without a dispatch hop.
    @discardableResult
    func applyLatestTitleIfAny() -> Bool {
        guard let session else { return false }
        let oscTitle = session.drain_latest_title().toString()
        // V3 fallback rule: an OSC title is *sticky* — it holds the
        // title bar until the child gives it back, exactly like every
        // other terminal. Ownership ends on one of two signals:
        //
        //  - `drain_title_reset()` — OSC 0/1/2 with an empty payload,
        //    alacritty's `Event::ResetTitle`, i.e. "I'm done with it".
        //  - leaving the alternate screen — vim / htop / less quitting
        //    without bothering to reset. (A shell with a title hook
        //    re-titles on its next prompt anyway; this covers the ones
        //    without.)
        //
        // This replaces a 500 ms recency window that let the
        // cwd-basename fallback overwrite a still-valid title after
        // half a second of quiet. Anything that titles once and then
        // works — `\e]2;building\a` before a long build, a shell hook
        // titling at exec time, any TUI that isn't a spinner — lost its
        // title mid-run, which read as "the title reverts under load".
        let altScreen = session.is_alt_screen()
        let altScreenExited = lastAltScreenForTitle && !altScreen
        lastAltScreenForTitle = altScreen
        stickyOscTitle = Self.nextTitleOwner(
            sticky: stickyOscTitle,
            oscTitle: oscTitle,
            reset: session.drain_title_reset(),
            altScreenExited: altScreenExited)
        let effective: String
        let subtitle: String
        if let sticky = stickyOscTitle {
            effective = sticky
            subtitle = lastCwd.isEmpty ? "" : Self.displayCwd(lastCwd)
        } else if !lastCwd.isEmpty {
            effective =
                (lastCwd as NSString).lastPathComponent.isEmpty
                ? lastCwd
                : (lastCwd as NSString).lastPathComponent
            subtitle = Self.displayCwd(lastCwd)
        } else {
            return false
        }
        var changed = false
        if hostWindow?.title != effective {
            hostWindow?.title = effective
            changed = true
        }
        // V3 subtitle gate: assigning `NSWindow.subtitle` on a window
        // without a fully-initialised titlebar (e.g. xctest-spun
        // windows that haven't been ordered front yet) raises
        // `NSInternalInconsistencyException: titlebarAccessoryViewControllers
        // not supported for this window style` because subtitle is
        // implemented under the hood as a titlebar accessory. Gate on
        // the window having a real close-button — a reliable signal
        // that AppKit has built the proper titlebar chrome.
        if let window = hostWindow,
            window.styleMask.contains(.titled),
            window.standardWindowButton(.closeButton) != nil,
            window.subtitle != subtitle
        {
            window.subtitle = subtitle
            changed = true
        }
        return changed
    }

    /// Who owns the title bar after this tick: the OSC title to show,
    /// or nil for the host's cwd-basename fallback.
    ///
    /// Pure so the rules can be pinned without a PTY. A title arriving
    /// in the same tick as a hand-back wins — the child re-titled, it
    /// did not walk away — though the FFI already keeps `reset` and a
    /// non-empty `oscTitle` mutually exclusive per drain.
    static func nextTitleOwner(
        sticky: String?,
        oscTitle: String,
        reset: Bool,
        altScreenExited: Bool
    ) -> String? {
        var owner = sticky
        if reset || altScreenExited { owner = nil }
        if !oscTitle.isEmpty { owner = oscTitle }
        return owner
    }

    /// V3: render a cwd absolute path with `$HOME` collapsed to `~`
    /// for a tidier subtitle. Common case is `/Users/<me>/foo` →
    /// `~/foo`; everything outside `$HOME` stays absolute.
    private static func displayCwd(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    @discardableResult
    func applyLatestCwdIfAny() -> Bool {
        guard let session else { return false }
        let cwd = session.drain_latest_cwd().toString()
        if !cwd.isEmpty, cwd != lastCwd {
            lastCwd = cwd
            return true
        }
        // V3 fallback: when the shell hasn't wired OSC 7, periodically
        // refresh `lastCwd` from `proc_pidinfo(child_pid)`. 500 ms is
        // slow enough to keep the FFI/proc call rare and fast enough
        // that the user sees the title flip within a frame or two
        // after `cd`. Skip while OSC 7 has been observed at least
        // once (the engine pushes events; we trust them).
        if cwd.isEmpty {
            let now = self.now()
            if now - lastCwdProcPollTime > 0.5 {
                lastCwdProcPollTime = now
                let pid = pid_t(session.child_pid())
                if pid > 0, let refreshed = Self.cwdForPid(pid),
                    refreshed != lastCwd
                {
                    lastCwd = refreshed
                    return true
                }
            }
        }
        return false
    }

    /// Best-effort working directory for ⌘N / ⌘T inheritance.
    /// Prefers OSC 7 (`lastCwd`) when the shell has emitted it; falls
    /// back to `proc_pidinfo` on the child PID so a vanilla zsh with no
    /// shell integration still inherits cwd — matches Terminal.app's
    /// behaviour. Returns nil if neither source has a value.
    func currentCwd() -> String? {
        if !lastCwd.isEmpty { return lastCwd }
        guard let session else { return nil }
        let pid = pid_t(session.child_pid())
        guard pid > 0 else { return nil }
        return Self.cwdForPid(pid)
    }

    /// macOS `proc_pidinfo(PROC_PIDVNODEPATHINFO)` cwd read. The
    /// implementation moved to `ProcessSnapshot` so `SessionJournal`'s
    /// off-main sampler can share it without depending on the renderer;
    /// this stays as the renderer's spelling of the same call.
    private static func cwdForPid(_ pid: pid_t) -> String? {
        ProcessSnapshot.cwd(forPid: pid)
    }
}
