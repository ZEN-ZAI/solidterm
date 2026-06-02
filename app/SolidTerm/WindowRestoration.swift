// macOS window restoration: reopen the previous set of terminal windows
// + native tabs on relaunch (and after crash / logout), each shell
// respawned in its saved working directory. LAYOUT + CWD ONLY — not live
// processes, not scrollback (matches Ghostty / iTerm2 visual restore).
//
// We delegate to Apple's NSWindowRestoration rather than inventing a
// session format: each TerminalWindowController window carries a
// restorationClass (this file) + a stable identifier; AppKit persists
// frame + tab-group membership and calls restoreWindow(...) once per
// saved window on next launch, where we rebuild the controller with the
// decoded cwd. See decisions / lazy-stirring-island.md for the design.

import AppKit

/// UserDefaults-backed toggle for window restoration. Follows the
/// per-feature key convention (TerminalInputSettings, AppearanceTab.Keys).
enum RestoreSettings {
    static let enabledKey = "solidterm.windowRestore.enabled"

    /// Default ON: unset reads as enabled, matching the Settings toggle.
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// NSCoder keys for the per-window restorable state.
enum RestoreCoderKeys {
    /// The session's working directory at encode time (OSC 7 / proc).
    static let cwd = "solidterm.restore.cwd"
    /// A non-default window title (program-set), if any.
    static let titleOverride = "solidterm.restore.titleOverride"
    // Reserved for a future manual tab-regroup fallback (encoded from day
    // one so enabling it needs no saved-state format migration). Not read
    // yet — AppKit-native tab restoration via the shared tabbingIdentifier
    // handles grouping today.
    static let groupId = "solidterm.restore.groupId"
    static let tabIndex = "solidterm.restore.tabIndex"
}

/// `NSWindowRestoration` implementation: rebuilds a terminal window from
/// the persisted cwd/title. AppKit invokes this around launch, once per
/// saved window identifier.
final class TerminalWindowRestorer: NSObject, NSWindowRestoration {
    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        // Opt-out: drop the saved window entirely. AppKit then treats it
        // as not-restored (the launch guard opens a fresh window instead).
        guard RestoreSettings.enabled else {
            completionHandler(nil, nil)
            return
        }

        let cwd = state.decodeObject(of: NSString.self, forKey: RestoreCoderKeys.cwd) as String?
        let title =
            state.decodeObject(of: NSString.self, forKey: RestoreCoderKeys.titleOverride) as String?
        let resolvedCwd = WindowRestorerSupport.resolveCwd(cwd)

        MainActor.assumeIsolated {
            let controller = TerminalWindowController(
                initialCwd: resolvedCwd, restoredTitle: title)
            // Re-key to the persisted identifier so AppKit lands the saved
            // frame + tab-group membership on this window.
            controller.window?.identifier = identifier
            (NSApp.delegate as? AppDelegate)?.adoptRestoredController(controller)
            // Do NOT showWindow — AppKit orders the returned window itself.
            completionHandler(controller.window, nil)
        }
    }
}

/// Pure cwd-resolution helper (no AppKit windows) so it's unit-testable.
enum WindowRestorerSupport {
    /// A saved cwd is used only if it still exists as a directory;
    /// otherwise `nil` so the session spawns at `NSHomeDirectory()`.
    static func resolveCwd(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir)
        return (exists && isDir.boolValue) ? cwd : nil
    }
}
