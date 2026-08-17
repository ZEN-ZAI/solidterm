// Minimal solidterm window controller. One pane per window; tabs +
// find bar + font-size hotkeys are preserved.
//
// All Claude-specific features (left sidebar, team task list, rate-limit
// HUD, block-timing HUD, team-pane event polling, native-mode toggle)
// were stripped when solidterm forked from SolidTerm.

import AppKit
import CoreText
import SwiftUI

final class TerminalWindowController: NSWindowController, NSMenuItemValidation {
    /// Lead pane id. Single pane per window in solidterm.
    static let leadPaneId: UInt64 = 1

    let paneSplitter: PaneSplitter
    private let leadPane: PaneViewController

    /// Test seam — read-only view of the lead pane's hosted NSView so
    /// E2E tests can reach the per-window renderer state without
    /// exposing the pane controller itself.
    var leadPaneViewForTesting: NSView { leadPane.view }

    /// Find-in-scrollback host. Lazy — first ⌘F builds the panel.
    private var searchPanelController: SearchPanelController?

    private let wrapper: WindowContentWrapper

    convenience init(
        initialCwd: String? = nil, restoredTitle: String? = nil,
        prefillCommand: String? = nil
    ) {
        let contentRect = NSRect(
            origin: .zero,
            size: TerminalSurfaceView.gridContentSize(cols: 80, rows: 24))

        let surfaceView = TerminalSurfaceView(frame: contentRect)
        if let cwd = initialCwd, !cwd.isEmpty {
            surfaceView.setInitialCwd(cwd)
        }
        if let prefillCommand, !prefillCommand.isEmpty {
            surfaceView.setPendingPrefill(prefillCommand)
        }
        var leadMeta = PaneViewController.PaneMetadata()
        leadMeta.title = "zsh"
        let leadPane = PaneViewController(
            paneId: TerminalWindowController.leadPaneId,
            view: surfaceView,
            metadata: leadMeta)

        let splitter = PaneSplitter(initial: leadPane)
        splitter.translatesAutoresizingMaskIntoConstraints = true
        splitter.autoresizingMask = [.width, .height]
        splitter.frame = contentRect

        let wrapper = WindowContentWrapper(frame: contentRect)
        wrapper.translatesAutoresizingMaskIntoConstraints = true
        wrapper.autoresizingMask = [.width, .height]
        wrapper.attachPaneSplitter(splitter)

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true)
        window.title = restoredTitle ?? "SolidTerm"
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        window.contentView = wrapper
        window.center()
        // Window restoration: a stable per-window identifier + the shared
        // restorationClass let AppKit persist this window's frame and tab
        // membership and re-create it on relaunch (see
        // WindowRestoration.swift). The shared tabbingIdentifier lets
        // AppKit re-group windows that were tabs. We deliberately do NOT
        // setFrameAutosaveName — a single name shared across every window
        // makes them clobber one frame slot; restoration owns per-window
        // frames via the identifier.
        window.identifier = NSUserInterfaceItemIdentifier(
            "SolidTermTerminal-\(UUID().uuidString)")
        window.restorationClass = TerminalWindowRestorer.self
        window.tabbingIdentifier = "SolidTermTerminalTabs"

        self.init(
            window: window,
            paneSplitter: splitter,
            leadPane: leadPane,
            wrapper: wrapper)
        DispatchQueue.main.async { [weak window, weak leadPane] in
            guard let w = window, let p = leadPane else { return }
            w.makeFirstResponder(p.view)
        }
    }

    /// Designated initializer.
    init(
        window: NSWindow,
        paneSplitter: PaneSplitter,
        leadPane: PaneViewController,
        wrapper: WindowContentWrapper
    ) {
        self.paneSplitter = paneSplitter
        self.leadPane = leadPane
        self.wrapper = wrapper
        super.init(window: window)
        observeThemeReload()
        observeCwdChange()
        ensureJournalRegistration()
    }

    /// Window-restoration state. The encoded cwd is captured live via
    /// `currentCwd()`; `invalidateRestorableState()` is called whenever
    /// the pane's cwd changes (observed below) so a relaunch respawns in
    /// the right directory even after a `cd` just before quit/crash.
    private var cwdChangeObserver: NSObjectProtocol?

    private func observeCwdChange() {
        cwdChangeObserver = NotificationCenter.default.addObserver(
            forName: MetalRenderer.cwdDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = self.window else { return }
            // Only react to OUR window's cwd change (object = host window).
            if (note.object as? NSWindow) === window {
                window.invalidateRestorableState()
                // Same notification doubles as the journal's registration
                // point: it fires on the first cwd after spawn, which is
                // the earliest moment `child_pid()` is valid, and on every
                // `cd` after that — so tab order and title stay fresh
                // without a second observer.
                self.registerWithJournal()
            }
        }
    }

    /// Stable key shared by `NSWindowRestoration` and the journal, so the
    /// two can be reconciled at launch without a second identifier scheme.
    var journalWindowID: String? { window?.identifier?.rawValue }

    /// The id this window is currently journalled under. Tracked because
    /// the identifier can change after init: `TerminalWindowRestorer` and
    /// the journal-fallback path both re-key a freshly built controller to
    /// the persisted identifier, so an early registration would otherwise
    /// strand an entry under the throwaway UUID.
    private var registeredJournalID: String?

    /// Fast-retry budget before `ensureJournalRegistration` backs off.
    private var journalRegistrationTicks = 0
    private static let journalFastRetries = 20
    private static let journalFastInterval: DispatchTimeInterval = .milliseconds(500)
    private static let journalSlowInterval: DispatchTimeInterval = .seconds(5)

    /// Keep trying to register until the PTY has actually spawned.
    ///
    /// Registration used to hang off the `cwdDidChange` notification alone,
    /// but that fires exactly ONCE for a shell that never leaves its
    /// starting directory — and the renderer DROPS it when `hostWindow` is
    /// still nil, consuming the change without ever posting. A window that
    /// lost that single event had no second chance, which is how live
    /// windows kept ending up absent from the journal (observed: 4 windows
    /// / 1 entry, then 2 windows / 1 entry).
    ///
    /// So this never gives up: it polls fast while the PTY is coming up,
    /// then backs off to a cheap 5s tick for the window's lifetime. The
    /// loop stops the moment registration succeeds, so a healthy window
    /// costs a handful of checks and nothing after that. A permanently
    /// unregistered window is silent data loss on the next crash; an idle
    /// 5s timer is not worth trading for that.
    private func ensureJournalRegistration() {
        if registerWithJournal() { return }
        journalRegistrationTicks += 1
        let delay =
            journalRegistrationTicks < Self.journalFastRetries
            ? Self.journalFastInterval : Self.journalSlowInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.ensureJournalRegistration()
        }
    }

    /// Publish this window's shell pid to `SessionJournal`. Idempotent —
    /// the journal keys on the window id and overwrites. Returns false
    /// while the session has yet to spawn, so the caller can retry.
    @discardableResult
    private func registerWithJournal() -> Bool {
        guard let window, let id = journalWindowID else { return false }
        guard
            let session = (leadPane.view as? TerminalSurfaceView)?
                .rendererForTesting.session
        else { return false }
        let pid = pid_t(session.child_pid())
        guard pid > 0 else { return false }

        // The identifier was re-keyed since we last registered — drop the
        // stale entry so the journal does not carry a phantom window.
        if let previous = registeredJournalID, previous != id {
            SessionJournal.shared.unregister(windowID: previous)
        }
        registeredJournalID = id

        // Tab-group membership: the first tab's identifier names the group,
        // and this window's position in it gives a stable restore order.
        let tabs = window.tabbedWindows ?? [window]
        let groupID = tabs.first?.identifier?.rawValue ?? id
        let order = tabs.firstIndex(of: window) ?? 0

        SessionJournal.shared.register(
            windowID: id, pid: pid, order: order, tabGroupID: groupID,
            title: window.title)
        return true
    }

    /// Encode the per-window restorable state: the session's working
    /// directory (so the restored shell spawns there) + a program-set
    /// title override. AppKit drives this on quit / periodic save.
    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        if let cwd = (leadPane.view as? TerminalSurfaceView)?
            .rendererForTesting.currentCwd(), !cwd.isEmpty
        {
            coder.encode(cwd as NSString, forKey: RestoreCoderKeys.cwd)
        }
        if let w = window, w.title != "SolidTerm", !w.title.isEmpty {
            coder.encode(w.title as NSString, forKey: RestoreCoderKeys.titleOverride)
        }
        // Read the command back from the journal's last sample rather than
        // re-scanning the process table here — this runs on the main thread
        // once per window per flush.
        if let id = journalWindowID,
            let command = SessionJournal.shared.lastEntry(forWindowID: id)?.command,
            !command.isEmpty
        {
            coder.encode(command as NSString, forKey: RestoreCoderKeys.command)
        }
    }

    override func restoreState(with coder: NSCoder) {
        // cwd/title are consumed by TerminalWindowRestorer at window-
        // creation time; nothing further to restore here. Call super for
        // any AppKit-managed state.
        super.restoreState(with: coder)
    }

    /// Q3 theme hot-reload toast. Listens for `ThemeFileStore.didChange`
    /// — fires both on user-driven `setActive` AND on the file-system
    /// watcher catching a TOML edit. The first event after launch is
    /// swallowed so the user doesn't see a redundant "Theme: …" toast
    /// every time they open a window. Subsequent events surface the
    /// new theme name (or "Default" when reverting to the built-in
    /// mode) as a transient toast at the bottom-center.
    private var themeReloadObserver: NSObjectProtocol?
    private var sawInitialThemeEvent = false

    private func observeThemeReload() {
        themeReloadObserver = NotificationCenter.default.addObserver(
            forName: ThemeFileStore.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleThemeReload() }
        }
    }

    @MainActor
    private func handleThemeReload() {
        guard sawInitialThemeEvent else {
            sawInitialThemeEvent = true
            return
        }
        let label: String
        if let name = ThemeFileStore.shared.current?.name {
            label = "Theme: \(name)"
        } else {
            label = "Theme: built-in (\(ThemeManager.shared.mode.label))"
        }
        ToastOverlay.shared.show(label, in: window)
    }

    deinit {
        if let obs = themeReloadObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = cwdChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalWindowController does not support storyboard instantiation")
    }

    // MARK: - View-menu selectors

    @objc public func increaseFontSize(_ sender: Any?) {
        dispatch(action: .increaseFontSize)
    }
    @objc public func decreaseFontSize(_ sender: Any?) {
        dispatch(action: .decreaseFontSize)
    }
    @objc public func resetFontSize(_ sender: Any?) {
        dispatch(action: .resetFontSize)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        return true
    }

    /// (title, cwd) snapshot for a terminal-switcher row. Title is the
    /// live window title (OSC 2 set-title, or cwd basename); cwd is the
    /// lead pane's current working directory (OSC 7, with a proc_pidinfo
    /// fallback). Read synchronously on the main thread — both are kept
    /// fresh by the renderer's display-link loop.
    var switcherSnapshot: (title: String, cwd: String) {
        let title = window?.title ?? "SolidTerm"
        let cwd =
            (leadPane.view as? TerminalSurfaceView)?
            .rendererForTesting.currentCwd() ?? ""
        return (title, cwd)
    }

    /// ⌘⇧O — present the app-global fuzzy terminal switcher, anchored on
    /// this window. The switcher itself is a singleton spanning all windows.
    @objc public func toggleTerminalSwitcher(_ sender: Any?) {
        TerminalSwitcherController.shared.toggle(anchor: window)
    }

    @objc public func toggleFindBar(_ sender: Any?) {
        let controller = ensureSearchPanelController()
        let surface = leadPane.view as? TerminalSurfaceView
        controller.bind(
            session: surface?.rendererForTesting.session,
            surface: surface)
        controller.toggle()
    }

    /// Tear down the ⌘F search panel when the window is closing. The
    /// panel is a standalone floating NSPanel (not a child window), so it
    /// would otherwise orphan on screen and leak its global event monitor
    /// when the window closes while the find bar is up.
    func closeSearchPanel() {
        searchPanelController?.forceClose()
    }

    private func ensureSearchPanelController() -> SearchPanelController {
        if let existing = searchPanelController { return existing }
        let controller = SearchPanelController()
        if let window {
            controller.attach(to: window)
        }
        searchPanelController = controller
        return controller
    }

    func dispatch(action: KeybindingAction) {
        switch action {
        case .openSettings:
            (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
        case .newWindow:
            (NSApp.delegate as? AppDelegate)?.openNewWindow()
        case .closeWindow:
            closeAllTabsInWindow()
        case .increaseFontSize:
            (leadPane.view as? TerminalSurfaceView)?
                .rendererForTesting.bumpFontSize()
        case .decreaseFontSize:
            (leadPane.view as? TerminalSurfaceView)?
                .rendererForTesting.dropFontSize()
        case .resetFontSize:
            (leadPane.view as? TerminalSurfaceView)?
                .rendererForTesting.resetFontSize()
        case .newTab:
            (NSApp.delegate as? AppDelegate)?.openNewTab(nil)
        case .closeTab:
            window?.performClose(nil)
        case .prevTab:
            window?.selectPreviousTab(nil)
        case .nextTab:
            window?.selectNextTab(nil)
        case .selectTab1, .selectTab2, .selectTab3, .selectTab4,
             .selectTab5, .selectTab6, .selectTab7, .selectTab8,
             .selectTab9:
            if let n = action.tabIndex {
                selectTab(byIndex: n)
            }
        case .openFindBar:
            toggleFindBar(nil)
        case .switchTerminal:
            toggleTerminalSwitcher(nil)
        case .installShellIntegration:
            ShellIntegrationInstaller.install()
        }
    }

    /// Return the lead pane (single-pane mode).
    func activePane() -> PaneViewController? { leadPane }

    /// Select the Nth tab (1-based) in the current window's tab group.
    func selectTab(byIndex n: Int) {
        guard n >= 1, let window else { return }
        let tabs = window.tabbedWindows ?? [window]
        guard n <= tabs.count else { return }
        tabs[n - 1].makeKeyAndOrderFront(nil)
    }

    @objc public func selectTab1(_ sender: Any?) { selectTab(byIndex: 1) }
    @objc public func selectTab2(_ sender: Any?) { selectTab(byIndex: 2) }
    @objc public func selectTab3(_ sender: Any?) { selectTab(byIndex: 3) }
    @objc public func selectTab4(_ sender: Any?) { selectTab(byIndex: 4) }
    @objc public func selectTab5(_ sender: Any?) { selectTab(byIndex: 5) }
    @objc public func selectTab6(_ sender: Any?) { selectTab(byIndex: 6) }
    @objc public func selectTab7(_ sender: Any?) { selectTab(byIndex: 7) }
    @objc public func selectTab8(_ sender: Any?) { selectTab(byIndex: 8) }
    @objc public func selectTab9(_ sender: Any?) { selectTab(byIndex: 9) }

    @objc public func closeWindowAndAllTabs(_ sender: Any?) {
        closeAllTabsInWindow()
    }

    private func closeAllTabsInWindow() {
        guard let window else { return }
        let tabs = window.tabbedWindows ?? [window]
        for tab in tabs {
            tab.performClose(nil)
        }
    }

    // MARK: - Test seams

    var contentWrapperForTests: WindowContentWrapper { wrapper }
}

/// Window content host. Owns the `paneSplitter` only; solidterm has no
/// sidebars.
final class WindowContentWrapper: NSView {
    private weak var paneSplitter: NSView?

    func attachPaneSplitter(_ view: NSView) {
        if view.superview === self { return }
        paneSplitter = view
        addSubview(view)
        layoutSubviews()
    }

    override func layout() {
        super.layout()
        layoutSubviews()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutSubviews()
    }

    private func layoutSubviews() {
        paneSplitter?.frame = bounds
    }
}
