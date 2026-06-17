// ⌘⇧O fuzzy terminal switcher — NSPanel controller.
//
// Sibling to SearchPanelController (⌘F): a floating, app-global overlay
// that lists every open terminal (one row per window AND per native tab)
// and focuses the chosen one. It is a singleton because the list spans
// all windows; it is opened from whichever terminal is key. The NSPanel
// lifecycle — `canBecomeKey` subclass, deferred first-responder, click-
// outside + resign-key dismiss, fade/slide animation — mirrors
// SearchPanelController exactly so the two overlays behave identically
// (and inherit the same first-responder fix, regression d2a966d).

import AppKit
import SwiftUI

@MainActor
final class TerminalSwitcherController: NSObject {
    /// App-global singleton — the switcher enumerates every window, so a
    /// single instance (like SettingsWindowController.shared) is correct.
    static let shared = TerminalSwitcherController()

    private weak var anchor: NSWindow?
    private let model = TerminalSwitcherModel()
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var isDismissing = false

    override init() {
        super.init()
        model.onActivate = { [weak self] entry in self?.activate(entry) }
        model.onDismiss = { [weak self] in self?.dismiss(animated: true) }
    }

    var isVisible: Bool {
        guard let p = panel, p.isVisible else { return false }
        return !isDismissing
    }

    /// Toggle the switcher, anchoring it on `anchor` (the key terminal
    /// window) for positioning. Bound to ⌘⇧O.
    func toggle(anchor: NSWindow?) {
        if isVisible {
            dismiss(animated: true)
        } else {
            present(anchor: anchor)
        }
    }

    // MARK: - Present / dismiss

    private func present(anchor: NSWindow?) {
        self.anchor = anchor ?? NSApp.keyWindow
        model.entries = Self.buildEntries()
        model.query = ""
        model.selectedIndex = 0

        let p = ensurePanel()
        sizePanel(p, entryCount: model.entries.count)
        positionPanel(p)
        isDismissing = false

        if !Self.reduceMotion() {
            let target = p.frame
            let start = NSRect(
                x: target.origin.x, y: target.origin.y + 4,
                width: target.width, height: target.height)
            p.setFrame(start, display: false)
            p.alphaValue = 0
            p.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.Motion.base
                ctx.timingFunction = CAMediaTimingFunction(
                    controlPoints:
                        Theme.Motion.easeOut.0, Theme.Motion.easeOut.1,
                        Theme.Motion.easeOut.2, Theme.Motion.easeOut.3)
                p.animator().setFrame(target, display: true)
                p.animator().alphaValue = 1
            }
        } else {
            p.alphaValue = 1
            p.makeKeyAndOrderFront(nil)
        }
        // Same SwiftUI @FocusState workaround as SearchPanelController:
        // make the wrapped NSTextField first responder one tick later.
        DispatchQueue.main.async { [weak self] in self?.focusField() }
        installClickOutsideMonitor()
    }

    private func dismiss(animated: Bool) {
        guard let p = panel, p.isVisible, !isDismissing else { return }
        removeClickOutsideMonitor()
        isDismissing = true

        if animated, !Self.reduceMotion() {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Theme.Motion.fast
                ctx.timingFunction = CAMediaTimingFunction(
                    controlPoints:
                        Theme.Motion.easeIn.0, Theme.Motion.easeIn.1,
                        Theme.Motion.easeIn.2, Theme.Motion.easeIn.3)
                p.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak p] in
                // If present() flipped isDismissing back to false while the
                // fade-out was in flight, the user re-opened the switcher —
                // bail without orderOut (same guard as SearchPanelController).
                guard let self, self.isDismissing else { return }
                p?.orderOut(nil)
                p?.alphaValue = 1
                self.isDismissing = false
                self.model.entries = []  // release window references
                self.restoreFocusToTerminal()
            })
        } else {
            p.orderOut(nil)
            p.alphaValue = 1
            isDismissing = false
            model.entries = []
            restoreFocusToTerminal()
        }
    }

    /// Re-key the anchor window after the panel orders out. A
    /// `.nonactivatingPanel` does not reliably hand key status back to the
    /// window it floated over, leaving the app with no key window and a
    /// dead keyboard (⌘F, ⌘V, typing) — the same defect fixed on
    /// `SearchPanelController.restoreFocusToTerminal`. Guarded so an
    /// app-switch dismissal doesn't yank focus back. `activate(_:)`
    /// re-keys its chosen window right after its `dismiss(animated:false)`
    /// returns, so this call is harmlessly overridden in that path.
    private func restoreFocusToTerminal() {
        guard NSApp.isActive else { return }
        // `anchor` can be nil here: if its window was closed while the
        // switcher was open, the switcher's `model.entries` held the last
        // strong reference and freed it in the dismiss completion that
        // just ran — so fall back to any live terminal window. Otherwise
        // the app is left with NO key window (dead keyboard), the exact
        // failure the ⌘F focus-restore guards against.
        let target = anchor
            ?? (NSApp.delegate as? AppDelegate)?.allWindowControllers
                .lazy.compactMap(\.window).first(where: \.isVisible)
        guard let target else { return }
        let key = NSApp.keyWindow
        if key == nil || key === panel {
            target.makeKey()
        }
    }

    private func activate(_ entry: TerminalSwitcherEntry) {
        dismiss(animated: false)
        // makeKeyAndOrderFront on a tabbed window selects that tab within
        // its group (same primitive as selectTab(byIndex:)). A closed
        // window's call is a harmless no-op.
        entry.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Entry enumeration

    /// Build one entry per live terminal. AppDelegate.windowControllers is
    /// already a flat list with one controller per window AND per native
    /// tab, so no tab-group expansion is needed (that would double-count).
    static func buildEntries() -> [TerminalSwitcherEntry] {
        guard let delegate = NSApp.delegate as? AppDelegate else { return [] }
        var entries: [TerminalSwitcherEntry] = []
        for controller in delegate.allWindowControllers {
            guard let window = controller.window else { continue }
            let snap = controller.switcherSnapshot
            entries.append(
                TerminalSwitcherEntry(
                    id: entries.count, window: window,
                    title: snap.title, cwd: snap.cwd))
        }
        return entries
    }

    // MARK: - Panel construction

    private func focusField() {
        guard let root = panel?.contentView else { return }
        func find(_ v: NSView) -> SwitcherTextField? {
            if let f = v as? SwitcherTextField { return f }
            for sub in v.subviews {
                if let f = find(sub) { return f }
            }
            return nil
        }
        if let field = find(root) {
            panel?.makeFirstResponder(field)
        }
    }

    private func ensurePanel() -> NSPanel {
        if let existing = panel { return existing }
        // Bare `NSHostingView`, not an `NSHostingController`, so SwiftUI
        // hijacks `NSApp.mainMenu` far less aggressively (the menu can still
        // get stripped — see the self-heal in
        // `AppDelegate.applicationDidUpdate`). Same pattern as
        // SearchPanelController / SettingsWindowController.
        let hostingView = NSHostingView(rootView: TerminalSwitcherView(model: model))

        let p = SwitcherPanel(
            contentRect: NSRect(
                x: 0, y: 0, width: TerminalSwitcherView.panelWidth, height: 200),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        // Same key-window invariant as SearchPanel — without it the
        // wrapped NSTextField never receives keystrokes (regression d2a966d).
        p.becomesKeyOnlyIfNeeded = false
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        hostingView.frame = p.contentLayoutRect
        hostingView.autoresizingMask = [.width, .height]
        p.contentView = hostingView
        p.contentView?.wantsLayer = true
        p.delegate = self
        self.panel = p
        return p
    }

    /// Size the panel to the query row + up to 8 visible rows; beyond that
    /// the list scrolls. Computed at present time from the entry count.
    private func sizePanel(_ p: NSPanel, entryCount: Int) {
        let visibleRows = CGFloat(min(max(entryCount, 1), 8))
        let height =
            TerminalSwitcherView.headerHeight + 1
            + visibleRows * TerminalSwitcherView.rowHeight
        p.setContentSize(
            NSSize(width: TerminalSwitcherView.panelWidth, height: height))
    }

    private func positionPanel(_ p: NSPanel) {
        let w = p.frame.width
        let h = p.frame.height
        if let anchor {
            let a = anchor.frame
            p.setFrame(
                NSRect(x: a.midX - w / 2, y: a.midY - h / 2, width: w, height: h),
                display: false)
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrame(
                NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h),
                display: false)
        }
    }

    // MARK: - Click-outside

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let p = self.panel, p.isVisible else { return event }
            if event.window !== p {
                self.dismiss(animated: true)
            }
            return event
        }
    }

    private func removeClickOutsideMonitor() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
    }

    static func reduceMotion() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

extension TerminalSwitcherController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSPanel) === panel {
            dismiss(animated: true)
        }
    }
}

/// Same `canBecomeKey` override as `SearchPanel` — without it the
/// borderless / nonactivating panel silently swallows keystrokes.
final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Fuzzy matcher

/// Tiny, dependency-free subsequence fuzzy matcher. `score` returns nil
/// when `needle` is not a subsequence of `haystack` (case-insensitive),
/// else a relevance score where higher is better — rewarding consecutive
/// matches, matches at word/path boundaries, and earlier matches. Greedy
/// leftmost matching (correct for subsequence existence; the alignment it
/// scores is the leftmost one, which is good enough for short queries).
enum FuzzyMatch {
    static func score(_ needle: String, _ haystack: String) -> Int? {
        let n = Array(needle.lowercased())
        if n.isEmpty { return 0 }
        let h = Array(haystack.lowercased())
        guard !h.isEmpty else { return nil }

        var score = 0
        var ni = 0
        var lastMatch = -1
        var hi = 0
        while hi < h.count, ni < n.count {
            if h[hi] == n[ni] {
                var bonus = 0
                if hi == lastMatch + 1 { bonus += 6 }  // consecutive run
                if hi == 0 {
                    bonus += 10  // very start of the haystack
                } else if isBoundary(h[hi - 1]) {
                    bonus += 9  // first char after a word / path boundary
                }
                let gap = hi - (lastMatch + 1)
                score += 12 + bonus - min(gap, 6)
                lastMatch = hi
                ni += 1
            }
            hi += 1
        }
        return ni == n.count ? score : nil
    }

    private static func isBoundary(_ c: Character) -> Bool {
        c == "/" || c == " " || c == "-" || c == "_" || c == "." || c == ":"
    }
}
