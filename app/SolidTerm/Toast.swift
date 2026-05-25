// Q3 — transient toast overlay shown on theme hot-reload (TOML edit
// applied) and any future "settings applied" notifications. Lives as
// a borderless child window so it floats above the Metal surface
// without forcing a redraw of the grid. AppKit auto-dismisses via
// timer; the controller cancels on subsequent show calls to debounce
// rapid notifications (e.g. user mass-edits a TOML).

import AppKit

@MainActor
final class ToastOverlay {
    static let shared = ToastOverlay()

    private var panel: NSPanel?
    private var dismissTimer: Timer?

    private init() {}

    /// Show a short status message anchored to the bottom-center of
    /// the parent window. The message replaces any prior in-flight
    /// toast (no queueing — the last action wins).
    func show(_ message: String, in parent: NSWindow?) {
        guard let parent else { return }
        dismissTimer?.invalidate()

        let panel = ensurePanel()
        let label = panel.contentView!.subviews.first as! NSTextField
        label.stringValue = message
        label.sizeToFit()

        // Resize panel around the label with 16pt horizontal padding
        // and 10pt vertical. Anchor near the bottom-center of the
        // parent window with a 32pt offset above the bottom edge.
        let padding = NSSize(width: 32, height: 20)
        let panelSize = NSSize(
            width: label.frame.width + padding.width,
            height: label.frame.height + padding.height)
        let parentFrame = parent.frame
        let origin = NSPoint(
            x: parentFrame.midX - panelSize.width / 2,
            y: parentFrame.minY + 32)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
        label.frame.origin = NSPoint(
            x: (panelSize.width - label.frame.width) / 2,
            y: (panelSize.height - label.frame.height) / 2)

        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: 1.8, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func dismiss() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating

        let bg = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false

        bg.addSubview(label)
        p.contentView = bg
        panel = p
        return p
    }
}
