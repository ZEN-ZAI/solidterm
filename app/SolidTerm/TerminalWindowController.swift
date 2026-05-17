// Minimal solidterm window controller. One pane per window; tabs +
// command palette + find bar + font-size hotkeys are preserved.
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

    /// Command palette host. Lazy — first ⌘K builds the panel.
    private var commandPaletteController: CommandPaletteController?

    /// Find-in-scrollback host. Lazy — first ⌘F builds the panel.
    private var searchPanelController: SearchPanelController?

    private let wrapper: WindowContentWrapper

    convenience init(initialCwd: String? = nil) {
        let contentRect = NSRect(
            origin: .zero,
            size: TerminalSurfaceView.gridContentSize(cols: 80, rows: 24))

        let surfaceView = TerminalSurfaceView(frame: contentRect)
        if let cwd = initialCwd, !cwd.isEmpty {
            surfaceView.setInitialCwd(cwd)
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
        window.title = "SolidTerm"
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        window.contentView = wrapper
        window.center()
        window.setFrameAutosaveName("SolidTermMainWindow")

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalWindowController does not support storyboard instantiation")
    }

    // MARK: - View-menu selectors

    @objc public func increaseFontSize(_ sender: Any?) {
        dispatch(paletteAction: .increaseFontSize)
    }
    @objc public func decreaseFontSize(_ sender: Any?) {
        dispatch(paletteAction: .decreaseFontSize)
    }
    @objc public func resetFontSize(_ sender: Any?) {
        dispatch(paletteAction: .resetFontSize)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        return true
    }

    @objc public func togglePalette(_ sender: Any?) {
        let controller = ensurePaletteController()
        controller.toggle()
    }

    @objc public func toggleFindBar(_ sender: Any?) {
        let controller = ensureSearchPanelController()
        let surface = leadPane.view as? TerminalSurfaceView
        controller.bind(
            session: surface?.rendererForTesting.session,
            surface: surface)
        controller.toggle()
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

    private func ensurePaletteController() -> CommandPaletteController {
        if let existing = commandPaletteController { return existing }
        let controller = CommandPaletteController()
        if let window {
            controller.attach(to: window)
        }
        controller.setDispatcher { [weak self] action in
            self?.dispatch(paletteAction: action)
        }
        commandPaletteController = controller
        return controller
    }

    func dispatch(paletteAction action: CommandPaletteAction) {
        switch action {
        case .openCommandPalette:
            break
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
