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

    /// SwiftUI's `NSHostingView` (find bar / terminal switcher) intermittently
    /// strips the File and Edit submenus out of `NSApp.mainMenu` after a few
    /// key-window transitions — every menu shortcut in them (⌘N, ⌘T, ⌘W, ⌘F,
    /// paste, …) then goes dead while typing still works. No app code mutates
    /// the menu and its object identity is unchanged, so it is an AppKit/
    /// SwiftUI mutation we can't cleanly suppress (tried `NSHostingView` over
    /// `NSHostingController`, and `sceneBridgingOptions = []` — both only
    /// reduce the frequency). `applicationDidUpdate` runs after each event
    /// batch, so restoring the menu here heals it within one cycle — before
    /// the user's next keypress. The guard makes it a cheap ~6-item scan that
    /// reinstalls only when the File menu has actually gone missing.
    func applicationDidUpdate(_ notification: Notification) {
        if NSApp.mainMenu?.items.contains(where: { $0.submenu?.title == "File" }) == false {
            AppMenu.install()
        }
    }

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
        // Durable cwd/command journal — a second record alongside AppKit's
        // saved state, sampled off the main thread (see SessionJournal).
        SessionJournal.shared.startSampling()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreUnclaimedJournalWindows()
            if self.windowControllers.isEmpty {
                self.openNewWindow()
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Second-chance restore for windows AppKit did not bring back.
    ///
    /// `NSWindowRestoration` stays the primary path — it owns frames and
    /// tab grouping — but it is best-effort: whatever it had not flushed
    /// when the process died is gone. Journal entries whose id no window
    /// claimed are reopened here. Runs inside the existing deferred block,
    /// after restoration has had its turn, which is what makes the
    /// claimed-set accurate and keeps the two from double-opening.
    private func restoreUnclaimedJournalWindows() {
        guard RestoreSettings.enabled else { return }
        let claimed = Set(windowControllers.compactMap { $0.journalWindowID })
        // Entries sharing a tabGroupID were tabs of one window, so they are
        // re-tabbed together rather than scattered into standalone windows.
        let ordered = SessionJournal.pendingGroups(
            from: SessionJournal.restoreSnapshot(), claimed: claimed)

        for group in ordered {
            var groupLead: NSWindow?
            for entry in group {
                let controller = makeJournalController(for: entry)
                guard let newWindow = controller.window else { continue }
                if let lead = groupLead, lead.tabbingMode != .disallowed {
                    lead.addTabbedWindow(newWindow, ordered: .above)
                    newWindow.orderFront(nil)
                } else {
                    controller.showWindow(nil)
                    groupLead = newWindow
                }
            }
        }
    }

    private func makeJournalController(
        for entry: SessionJournalEntry
    ) -> TerminalWindowController {
        let title = (entry.title.isEmpty || entry.title == "SolidTerm") ? nil : entry.title
        let controller = TerminalWindowController(
            initialCwd: WindowRestorerSupport.resolveCwd(entry.cwd),
            restoredTitle: title,
            prefillCommand: WindowRestorerSupport.resolveCommand(entry.command))
        // Reuse the journal's id as the window identifier so the next
        // launch reconciles against the same key instead of leaking a
        // fresh UUID per restore.
        controller.window?.identifier = NSUserInterfaceItemIdentifier(entry.id)
        windowControllers.append(controller)
        controller.window?.delegate = self
        return controller
    }

    /// True once the app has committed to quitting.
    ///
    /// AppKit closes every window on the way out, which fires
    /// `windowWillClose` for each — indistinguishable, without this flag,
    /// from the user deliberately closing a tab. Treating those as
    /// deliberate would unregister every window and leave an EMPTY journal
    /// after a normal ⌘Q — the journal would then only ever help after a
    /// crash and never after a clean quit. The flag keeps "app is quitting"
    /// and "user closed this window" apart.
    private var isTerminating = false

    /// Fires before the windows are torn down, so this is where the
    /// terminating flag has to be set. Flush here too: the journal should
    /// reflect the final state, not whatever the 5s sampler last caught.
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        isTerminating = true
        SessionJournal.shared.flushSynchronously()
        return .terminateNow
    }

    /// Last chance to capture state before the process goes away.
    /// Synchronous on purpose — returning before the write lands would
    /// defeat the point.
    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        SessionJournal.shared.flushSynchronously()
    }

    /// Cheap insurance: the user switching away is a good moment to make
    /// sure what is on disk matches what is on screen.
    func applicationDidResignActive(_ notification: Notification) {
        SessionJournal.shared.flushNow()
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
        // Dismiss the window's find bar BEFORE releasing its controller —
        // the floating search panel isn't a child window, so it won't be
        // torn down automatically and would ghost on screen.
        windowControllers.first { $0.window === closing }?.closeSearchPanel()
        // Drop the journal entry too — a deliberately closed window must
        // not come back on the next launch. Skipped while terminating:
        // those closes are AppKit tearing down on quit, not the user
        // dismissing a window, and unregistering them would wipe the very
        // state we are quitting with (see `isTerminating`).
        if !isTerminating, let id = closing.identifier?.rawValue {
            SessionJournal.shared.unregister(windowID: id)
        }
        windowControllers.removeAll { $0.window === closing }
    }
}
