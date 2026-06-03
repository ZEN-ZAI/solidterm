// Implements spec/swift-app-modules.md §App Lifecycle and `@main`.
// AppDelegate creates the first TerminalWindowController on launch and
// terminates the process when the last window closes.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [TerminalWindowController] = []

    /// Every live terminal window controller — one per window AND per
    /// native tab (each tab is its own controller). The terminal switcher
    /// (⌘⇧O) reads this to enumerate every open terminal as a flat list.
    var allWindowControllers: [TerminalWindowController] { windowControllers }

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
        // Keep windows on Cmd-Q so NSWindowRestoration reopens the
        // previous terminals on relaunch regardless of the system "Close
        // windows when quitting an app" preference. AppKit reads this from
        // the defaults domain; `register` provides it as a fallback so an
        // explicit user override still wins. (The Info.plist key isn't a
        // recognized GENERATE_INFOPLIST_FILE passthrough, so we set it
        // here instead of in project.yml.)
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": true])
        // Defer the "open a window" decision one runloop turn. AppKit's
        // window restoration invokes TerminalWindowRestorer.restoreWindow
        // around launch, and those controllers register synchronously via
        // adoptRestoredController. Deferring lets us count restored windows
        // first and open a fresh one ONLY when nothing was restored —
        // otherwise every launch would get a spurious extra empty window.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.windowControllers.isEmpty {
                self.openNewWindow()
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// macOS 12+ requires apps to opt into secure state restoration. Our
    /// restorable state is NSString-only (cwd / title), so it is
    /// secure-coding-safe.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Dock-icon click / reopen with no visible windows → open one.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag, windowControllers.isEmpty {
            openNewWindow()
        }
        return true
    }

    /// Register a controller created by window restoration so it shares
    /// the same ownership + `windowWillClose` pruning as ⌘N / ⌘T windows.
    /// Idempotent. Does NOT `showWindow` — AppKit orders the restored
    /// window itself once we return it from the restorer.
    func adoptRestoredController(_ controller: TerminalWindowController) {
        if !windowControllers.contains(where: { $0 === controller }) {
            windowControllers.append(controller)
        }
        controller.window?.delegate = self
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

    /// Read the active pane's working directory so ⌘N / ⌘T inherit it.
    /// Prefers OSC 7 (cached as `lastCwd` from `drain_latest_cwd()`) and
    /// falls back to `proc_pidinfo` on the shell PID — so a fresh zsh
    /// with no shell integration still propagates cwd. Returns nil when
    /// no terminal window is key (app launch, settings window front,
    /// etc.); caller falls back to `NSHomeDirectory()`.
    private static func activePaneCwd() -> String? {
        guard let keyWindow = NSApp.keyWindow,
            let contentView = keyWindow.contentView
        else { return nil }
        guard let surface = Self.findSurfaceView(in: contentView) else {
            return nil
        }
        return surface.rendererForTesting.currentCwd()
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

    /// Q1: custom About panel. AppKit's stock panel reads version
    /// + copyright from Info.plist but defaults the credits pane to
    /// an empty box. We populate it with the project's one-line
    /// description + a credit to alacritty_terminal (the engine
    /// solidterm builds on). `applicationName` falls back to
    /// `CFBundleName`; everything else flows through the standard
    /// keys so the user gets the native macOS About chrome.
    @objc func showAboutPanel(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string:
                "A minimal, fast, solid native macOS terminal.\n\n"
                + "Built on alacritty_terminal + swift-bridge.\n"
                + "Forked from NextTerm — Claude integration stripped.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windowControllers.removeAll { $0.window === closing }
    }
}
