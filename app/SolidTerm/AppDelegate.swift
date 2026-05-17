// Implements spec/swift-app-modules.md §App Lifecycle and `@main`.
// AppDelegate creates the first TerminalWindowController on launch and
// terminates the process when the last window closes.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [TerminalWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenu.install()
        // ⌘N must always create a standalone window. AppKit's automatic
        // window tabbing (driven by the system-wide "Prefer tabs when
        // opening documents" preference) would otherwise fold the new
        // window into the key window's tab group, making ⌘N behave
        // identically to ⌘T. ⌘T still explicitly calls addTabbedWindow,
        // so tabs remain accessible — but the user opt-in is now the
        // ONLY path that produces a tab.
        NSWindow.allowsAutomaticWindowTabbing = false
        openNewWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func openNewWindow() {
        let controller = TerminalWindowController(
            initialCwd: Self.activePaneCwd())
        windowControllers.append(controller)
        controller.window?.delegate = self
        controller.showWindow(nil)
    }

    /// M7-5 — Open a new tab in the current key window's tab group.
    /// Falls back to a fresh standalone window when there's no key window
    /// (e.g. invoked from a non-Terminal context or from an empty app
    /// state). The new tab carries its own `EngineSession`/lead pane via
    /// `TerminalWindowController()`'s convenience init.
    @objc func openNewTab(_ sender: Any?) {
        let controller = TerminalWindowController(
            initialCwd: Self.activePaneCwd())
        windowControllers.append(controller)
        controller.window?.delegate = self
        guard let newWindow = controller.window else { return }
        if let keyWindow = NSApp.keyWindow,
            keyWindow !== newWindow,
            keyWindow.tabbingMode != .disallowed
        {
            keyWindow.addTabbedWindow(newWindow, ordered: .above)
            newWindow.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
        }
    }

    /// Read the active pane's OSC 7-reported cwd so ⌘N / ⌘T inherit
    /// the source window's working directory. Returns nil when no
    /// terminal window is key (app launch, settings window front, etc.)
    /// or when the shell hasn't emitted OSC 7 yet — caller falls back
    /// to `NSHomeDirectory()`. The cwd is cached on the renderer by
    /// `applyLatestCwdIfAny` from `drain_latest_cwd()`; this just
    /// surfaces it from whichever TerminalSurfaceView is in the key
    /// window's view hierarchy.
    private static func activePaneCwd() -> String? {
        guard let keyWindow = NSApp.keyWindow,
            let contentView = keyWindow.contentView
        else { return nil }
        guard let surface = Self.findSurfaceView(in: contentView) else {
            return nil
        }
        let cwd = surface.rendererForTesting.lastCwd
        return cwd.isEmpty ? nil : cwd
    }

    /// Depth-first walk of the view tree looking for the first
    /// `TerminalSurfaceView`. Pane splitters wrap the surface in
    /// containers (`WindowContentWrapper` → `PaneSplitter` → pane
    /// `NSView` → surface), so we can't reach the surface through a
    /// known path without re-implementing the splitter contract.
    private static func findSurfaceView(in view: NSView) -> TerminalSurfaceView? {
        if let surface = view as? TerminalSurfaceView { return surface }
        for sub in view.subviews {
            if let found = findSurfaceView(in: sub) { return found }
        }
        return nil
    }

    /// M5-2 — wired from `AppMenu`'s "Preferences…" item. Selector
    /// targets always dispatch on the main thread; `MainActor.assumeIsolated`
    /// makes the isolation explicit so the call into the MainActor-
    /// isolated `SettingsWindowController.shared` type-checks.
    @objc func openSettingsWindow() {
        MainActor.assumeIsolated {
            SettingsWindowController.shared.showWindow(nil)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windowControllers.removeAll { $0.window === closing }
    }
}
