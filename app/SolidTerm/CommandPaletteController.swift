// M6-1 Command Palette — `NSPanel` controller (host for the SwiftUI view).
//
// Architecture per spec/swift-app-modules.md §Command Palette:
// - non-activating `NSPanel` so the active pane keeps key focus while
//   the panel is on screen — the panel's text field grabs focus only
//   for input, not for the whole responder chain
// - top-center positioning ~88pt from window top, 560pt fixed width
// - 4pt downward slide + fade on entry (motion-base 150ms ease-out);
//   fade-out on dismiss (motion-fast 100ms ease-in); reduced-motion gate
//   per `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`
// - click-outside dismiss via local NSEvent monitor for left/right mouse
// - Escape dismiss handled inside the SwiftUI search field
//
// Out of scope (deferred to M3+/Phase-2 per research/20-m6-plan.md §M6-1):
// - FocusStackManager parallel responder chain
// - Plugin-source live sync from system/init.commands[]
// - PaletteEntry / CommandKind dispatch (allowedTools whitelist, etc.)
// - Recent / Suggested / Built-in / Plugin sectioning
// - `/` filter prefix to filter by command source

import AppKit
import SwiftUI

/// Owns a single floating `NSPanel`, lazily created on first show.
/// Per-window controller — `TerminalWindowController` instantiates one
/// and binds ⌘K through the AppMenu.
@MainActor
public final class CommandPaletteController: NSObject {
    /// Anchor window above which the palette positions itself. Weak so
    /// closing the window cleans up automatically.
    private weak var anchor: NSWindow?

    /// Selector handler for the menu-bar ⌘K item — provided at install
    /// time so AppMenu can target the active window's controller via
    /// the responder chain. Stays nil until `attach(to:)` is called.
    private(set) var dispatcher: (CommandPaletteAction) -> Void = { _ in }

    private let model: CommandPaletteModel
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    /// Tracks user-visible intent during an in-flight dismiss
    /// animation. `panel.isVisible` stays true until `orderOut` runs
    /// in the animation completion handler, so without this flag
    /// `isVisible` would report stale "still up" until the fade
    /// finishes. Flipped true at the start of `dismiss()` so
    /// `isVisible` reflects the requested state immediately.
    private var isDismissing: Bool = false

    public init(
        actions: [CommandPaletteAction] = CommandPaletteAction.paletteVisible
    ) {
        self.model = CommandPaletteModel(actions: actions)
        super.init()
        model.onCommit = { [weak self] action in
            guard let self else { return }
            self.dispatcher(action)
            self.dismiss(animated: true)
        }
        model.onDismiss = { [weak self] in
            self?.dismiss(animated: true)
        }
    }

    public func attach(to window: NSWindow) {
        self.anchor = window
    }

    /// Wire the action dispatcher. The host (TerminalWindowController)
    /// supplies a closure that maps each action to its concrete handler
    /// — keeps the controller decoupled from AppMenu / window state.
    public func setDispatcher(
        _ dispatch: @escaping (CommandPaletteAction) -> Void
    ) {
        self.dispatcher = dispatch
    }

    public var isVisible: Bool {
        guard let p = panel, p.isVisible else { return false }
        return !isDismissing
    }

    /// Toggle visibility — called from ⌘K binding.
    @objc public func toggle() {
        if isVisible {
            dismiss(animated: true)
        } else {
            present(animated: true)
        }
    }

    // MARK: - Present

    private func present(animated: Bool) {
        let p = ensurePanel()
        positionPanel(p)
        model.reset()
        isDismissing = false

        // Always show at full opacity. The earlier "alpha 0 → 1 + 4pt
        // slide" animation occasionally stuck `alphaValue` at 0 in
        // production (invisible panel — `nbasic`เยอะ` report 2026-05-11)
        // because the animation context sometimes failed to commit on
        // an `.nonactivatingPanel + .fullSizeContentView` panel. The
        // animation was a nicety; the snap-in is acceptable.
        p.alphaValue = 1
        p.makeKeyAndOrderFront(nil)
        _ = animated  // silence unused arg
        // SwiftUI's `@FocusState` does not propagate first-responder
        // status into an NSViewRepresentable's NSTextField, so the
        // search field stays untyped until we explicitly hand it
        // first responder. Deferred one tick so the SwiftUI hosting
        // view has finished mounting.
        DispatchQueue.main.async { [weak self] in
            self?.focusSearchField()
        }
        installClickOutsideMonitor()
    }

    private func focusSearchField() {
        guard let root = panel?.contentView else { return }
        func find(_ v: NSView) -> CommandPaletteTextField? {
            if let f = v as? CommandPaletteTextField { return f }
            for sub in v.subviews {
                if let f = find(sub) { return f }
            }
            return nil
        }
        if let field = find(root) {
            panel?.makeFirstResponder(field)
        }
    }

    // MARK: - Dismiss

    private func dismiss(animated: Bool) {
        guard let p = panel, p.isVisible, !isDismissing else { return }
        removeClickOutsideMonitor()
        isDismissing = true

        let reduce = Self.reduceMotion()
        if animated, !reduce {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Theme.Motion.fast
                ctx.timingFunction = CAMediaTimingFunction(
                    controlPoints:
                        Theme.Motion.easeIn.0, Theme.Motion.easeIn.1,
                        Theme.Motion.easeIn.2, Theme.Motion.easeIn.3)
                p.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak p] in
                p?.orderOut(nil)
                p?.alphaValue = 1
                self?.isDismissing = false
            })
        } else {
            p.orderOut(nil)
            p.alphaValue = 1
            isDismissing = false
        }
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let existing = panel { return existing }
        let host = NSHostingController(
            rootView: CommandPaletteView(model: model))
        // Sizing: width fixed at 560; intrinsic height up to 480.
        host.view.translatesAutoresizingMaskIntoConstraints = false

        let p = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 144),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        // Must become key when shown so the SwiftUI TextField inside
        // receives keystrokes. `.nonactivatingPanel` keeps the parent
        // app from deactivating, but the panel itself still needs key
        // status for input. With `becomesKeyOnlyIfNeeded = true` +
        // `orderFront`, the panel rendered but never accepted typing.
        p.becomesKeyOnlyIfNeeded = false
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.contentViewController = host
        p.contentView?.wantsLayer = true
        p.delegate = self
        self.panel = p
        return p
    }

    private func positionPanel(_ p: NSPanel) {
        guard let anchor else {
            // Center on main screen as a fallback.
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                let x = f.midX - 280
                let y = f.midY + 200
                p.setFrameOrigin(NSPoint(x: x, y: y))
            }
            return
        }
        let aFrame = anchor.frame
        let panelHeight = p.frame.height
        let panelWidth: CGFloat = 560
        let topGap: CGFloat = 88

        // AppKit window coordinates: origin is bottom-left, so
        // top-of-window = aFrame.origin.y + aFrame.height. Panel
        // top edge sits `topGap` below that; convert to bottom-left
        // origin by subtracting panelHeight.
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

    // MARK: - Reduced-motion gate

    /// Static so tests can sample without a live `NSWorkspace`.
    static func reduceMotion() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

// MARK: - NSWindowDelegate

extension CommandPaletteController: NSWindowDelegate {
    public func windowDidResignKey(_ notification: Notification) {
        // Panel losing key focus = user clicked through to another
        // window. Dismiss to keep the floating panel from sticking
        // around behind the active window.
        if (notification.object as? NSPanel) === panel {
            dismiss(animated: true)
        }
    }
}

/// `NSPanel` defaults `canBecomeKeyWindow` to `false` for borderless /
/// nonactivating styles, which silently swallows keystrokes inside the
/// hosted SwiftUI text field. Override here so the palette can take
/// keyboard focus while `.nonactivatingPanel` keeps the parent app
/// from deactivating.
final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
