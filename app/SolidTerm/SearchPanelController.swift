// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// M7-2 ⌘F find-in-scrollback — `NSPanel` controller hosting the search
// UI. Mirrors `CommandPaletteController`'s panel pattern (regression
// `d2a966d` — `canBecomeKey` override + deferred `makeFirstResponder`)
// so the same first-responder bug doesn't recur on the find bar.
//
// Behavior:
// - present: build panel, position top-center 88pt below the anchor's
//   top edge, fade + slide in (4pt downward), grab key for typing
// - dismiss: fade out 100ms, clear search highlights on the renderer
// - Return / ↓: jump to next match (auto-scroll); Shift-Return / ↑:
//   previous; Esc: dismiss
// - regex toggle (.* checkbox) re-runs search on flip
// - "n of m" indicator updates as the user types
// - click outside dismisses
//
// The controller owns the SearchModel (query / regex / matches /
// activeIndex) and a weak reference to the active terminal session +
// surface view so it can run `session.search()` and publish highlight
// rows back to the renderer's `searchHighlights` field.

import AppKit
import SwiftUI

/// Owns the search `NSPanel`, its SwiftUI host view, and the model.
@MainActor
public final class SearchPanelController: NSObject {
    private weak var anchor: NSWindow?
    private weak var session: TerminalSession?
    /// Surface view whose renderer publishes search highlights. Weak so
    /// closing the window cleans up automatically.
    private weak var surface: TerminalSurfaceView?

    private let model: SearchPanelModel
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var isDismissing: Bool = false

    public override init() {
        self.model = SearchPanelModel()
        super.init()
        model.onCommit = { [weak self] direction in
            self?.jump(direction: direction)
        }
        model.onDismiss = { [weak self] in
            self?.dismiss(animated: true)
        }
        model.onSearch = { [weak self] in
            self?.runSearch()
        }
    }

    deinit {
        // Backstop: if the controller is released without a user dismiss
        // (window closed while the find bar was up), unregister the
        // global click-outside monitor so it doesn't leak for the app's
        // lifetime. `forceClose()` from the window-close path is the
        // primary, deterministic cleanup; this catches any path missing it.
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m) }
    }

    public func attach(to window: NSWindow) {
        self.anchor = window
    }

    func bind(session: TerminalSession?, surface: TerminalSurfaceView?) {
        self.session = session
        self.surface = surface
    }

    public var isVisible: Bool {
        guard let p = panel, p.isVisible else { return false }
        return !isDismissing
    }

    /// Toggle visibility — bound to ⌘F.
    @objc public func toggle() {
        if isVisible {
            dismiss(animated: true)
        } else {
            present(animated: true)
        }
    }

    // MARK: - Present / dismiss

    private func present(animated: Bool) {
        let p = ensurePanel()
        positionPanel(p)
        // Don't reset query — match Ghostty / iTerm2 (re-opening the
        // bar surfaces the previous search). Highlights re-apply via
        // `runSearch()` below.
        isDismissing = false

        let reduce = Self.reduceMotion()
        if animated, !reduce {
            let target = p.frame
            let start = NSRect(
                x: target.origin.x,
                y: target.origin.y + 4,
                width: target.width,
                height: target.height)
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
        // Same SwiftUI @FocusState workaround as CommandPaletteController:
        // make the wrapped NSTextField first responder one tick later.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusSearchField()
            // Re-run search if we have a query already (re-opening with
            // a previous query restores its highlights).
            if !self.model.query.isEmpty {
                self.runSearch()
            }
        }
        installClickOutsideMonitor()
    }

    private func focusSearchField() {
        guard let root = panel?.contentView else { return }
        func find(_ v: NSView) -> SearchPanelTextField? {
            if let f = v as? SearchPanelTextField { return f }
            for sub in v.subviews {
                if let f = find(sub) { return f }
            }
            return nil
        }
        if let field = find(root) {
            panel?.makeFirstResponder(field)
            // Select existing text so a fresh keystroke replaces it.
            field.selectText(nil)
        }
    }

    private func dismiss(animated: Bool) {
        guard let p = panel, p.isVisible, !isDismissing else { return }
        removeClickOutsideMonitor()
        isDismissing = true
        // Clear highlights immediately so the next frame paints clean.
        surface?.rendererForTesting.searchHighlights = nil

        let reduce = Self.reduceMotion()
        if animated, !reduce {
            NSAnimationContext.runAnimationGroup(
                { ctx in
                    ctx.duration = Theme.Motion.fast
                    ctx.timingFunction = CAMediaTimingFunction(
                        controlPoints:
                            Theme.Motion.easeIn.0, Theme.Motion.easeIn.1,
                        Theme.Motion.easeIn.2, Theme.Motion.easeIn.3)
                    p.animator().alphaValue = 0
                },
                completionHandler: { [weak self, weak p] in
                    // If `present()` reset `isDismissing` to false while
                    // our fade-out was in flight, the user has re-opened
                    // the panel with ⌘F and a fresh fade-in is already
                    // animating. Bail without `orderOut` — otherwise we
                    // re-hide the panel the user just asked to see and
                    // the second ⌘F appears to "not open" (reproduced
                    // 2026-05-19).
                    guard let self, self.isDismissing else {
                        // Still keep the visual state consistent for the
                        // panel handle the previous flow grabbed — but
                        // don't touch the panel because it may have been
                        // re-presented with its own animator's alpha.
                        return
                    }
                    p?.orderOut(nil)
                    p?.alphaValue = 1
                    self.isDismissing = false
                    self.restoreFocusToTerminal()
                })
        } else {
            p.orderOut(nil)
            p.alphaValue = 1
            isDismissing = false
            restoreFocusToTerminal()
        }
    }

    /// Hand key status + first responder back to the terminal window the
    /// panel floated over. A `.nonactivatingPanel` grabs key on present
    /// (`canBecomeKey == true`) but, on `orderOut`, AppKit does NOT
    /// reliably restore key to the window underneath — it can leave the
    /// app with NO key window, which silently kills every keyboard path
    /// (⌘F, ⌘V, plain typing) until another window is clicked. That's the
    /// "find works once then the keyboard is dead" defect. Re-key the
    /// anchor explicitly.
    ///
    /// Guarded so an app-switch dismissal — the user clicks another app,
    /// the panel resigns key, `windowDidResignKey` fires `dismiss` — does
    /// NOT yank focus back into our app: only reclaim when our app is
    /// still active and nothing other than the (now-hidden) panel holds
    /// key. The terminal window keeps its own first responder across a
    /// key loss, so `makeFirstResponder` is belt-and-suspenders for the
    /// rare case it was cleared.
    private func restoreFocusToTerminal() {
        guard NSApp.isActive, let anchor else { return }
        let key = NSApp.keyWindow
        if key == nil || key === panel {
            anchor.makeKey()
        }
        if let surface, anchor.firstResponder !== surface {
            anchor.makeFirstResponder(surface)
        }
    }

    /// Synchronous teardown for when the owning window closes while the
    /// panel is still visible (⌘W without Esc). `dismiss()` never runs in
    /// that path, so the floating panel would orphan on screen and the
    /// click-outside monitor would leak. Orders the panel out and removes
    /// the monitor immediately.
    func forceClose() {
        removeClickOutsideMonitor()
        surface?.rendererForTesting.searchHighlights = nil
        isDismissing = false
        panel?.orderOut(nil)
        panel?.alphaValue = 1
    }

    // MARK: - Search core

    /// Run the search via FFI, decode results, publish highlights.
    func runSearch() {
        guard let session else {
            model.matches = []
            model.activeIndex = nil
            model.parseError = nil
            surface?.rendererForTesting.searchHighlights = nil
            return
        }
        let query = model.query
        if query.isEmpty {
            model.matches = []
            model.activeIndex = nil
            model.parseError = nil
            surface?.rendererForTesting.searchHighlights = nil
            return
        }
        let payload = session.search(query, model.useRegex)
        let decoded: [SearchMatchSwift]
        do {
            decoded = try SearchMatchDecoding.decode(payload)
        } catch {
            decoded = []
        }
        let err = session.last_search_error().toString()
        model.parseError = err.isEmpty ? nil : err
        model.matches = decoded
        // Preserve activeIndex when the matches list changes but the
        // current match still exists; otherwise reset to 0.
        if decoded.isEmpty {
            model.activeIndex = nil
        } else if let cur = model.activeIndex, cur < decoded.count {
            // keep
        } else {
            model.activeIndex = 0
        }
        publishHighlights()
        scrollActiveIntoView()
    }

    /// Publish the full match list (with alacritty-absolute lines) to
    /// the renderer. The renderer's encode path translates to viewport
    /// row every frame using its cached `scroll_top`, so highlights
    /// track content as the user scrolls without re-publishing.
    private func publishHighlights() {
        guard let renderer = surface?.rendererForTesting else { return }
        let spans = model.matches.map { m in
            MetalRenderer.SearchHighlights.Span(
                line: Int(m.line),
                startCol: Int(m.col),
                span: Int(m.len))
        }
        renderer.searchHighlights = MetalRenderer.SearchHighlights(
            spans: spans, activeIndex: model.activeIndex)
    }

    /// `direction = .next` advances activeIndex by 1, `.previous` by -1
    /// (wrap-around). Idempotent on empty match list.
    private func jump(direction: SearchPanelModel.JumpDirection) {
        guard !model.matches.isEmpty else { return }
        let n = model.matches.count
        let cur = model.activeIndex ?? 0
        let next: Int
        switch direction {
        case .next: next = (cur + 1) % n
        case .previous: next = (cur - 1 + n) % n
        }
        model.activeIndex = next
        scrollActiveIntoView()
        publishHighlights()
    }

    private func scrollActiveIntoView() {
        guard let session,
            let i = model.activeIndex,
            i < model.matches.count
        else { return }
        let m = model.matches[i]
        session.scroll_to_line(m.line)
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let existing = panel { return existing }
        // Host the SwiftUI body in a bare `NSHostingView`, not an
        // `NSHostingController`: as a panel's `contentViewController` the
        // controller hijacks `NSApp.mainMenu` aggressively. The plain view
        // still lets AppKit strip the File/Edit menus occasionally (see the
        // self-heal in `AppDelegate.applicationDidUpdate`), but far less
        // often, so the menu bar barely churns.
        let hostingView = NSHostingView(rootView: SearchPanelView(model: model))

        let p = SearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 56),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        // Same key-window invariant as CommandPalettePanel — without
        // this the wrapped NSTextField never receives keystrokes
        // (regression `d2a966d`).
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

    private func positionPanel(_ p: NSPanel) {
        guard let anchor else {
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                let x = f.midX - 240
                let y = f.midY + 200
                p.setFrameOrigin(NSPoint(x: x, y: y))
            }
            return
        }
        let aFrame = anchor.frame
        let panelHeight = p.frame.height
        let panelWidth: CGFloat = 480
        let topGap: CGFloat = 88

        // Top-center, same idiom as CommandPaletteController.
        let x = aFrame.midX - panelWidth / 2
        let topY = aFrame.maxY - topGap
        let y = topY - panelHeight
        p.setFrame(
            NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            display: false)
    }

    // MARK: - Click-outside

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self,
                let p = self.panel,
                p.isVisible
            else { return event }
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

extension SearchPanelController: NSWindowDelegate {
    public func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSPanel) === panel {
            dismiss(animated: true)
        }
    }
}

/// Same `canBecomeKey` override as `CommandPalettePanel` — without it
/// the borderless / nonactivating panel silently swallows keystrokes.
final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
