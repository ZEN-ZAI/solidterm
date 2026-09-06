// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// The Settings window.
//
// `SettingsWindowController : NSWindowController` wraps `SettingsView`
// (SwiftUI) via `NSHostingController`. SwiftUI's `Settings { }` scene
// stays empty — `AppMenu` wires Preferences directly to
// `showWindow(_:)` here instead. Single shared instance per app,
// lazy-init on first showWindow.

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {

    /// Shared instance owned by `AppDelegate`; `AppMenu`'s Preferences
    /// item calls into it via the responder chain.
    static let shared = SettingsWindowController()

    private convenience init() {
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let view = SettingsView(tabs: SettingsTab.defaults(projectRoot: projectRoot))
        // Build the window with the full styleMask up front. Setting
        // styleMask AFTER assigning a contentViewController on macOS
        // 14+ can leave the hosted SwiftUI view unattached — the
        // window draws its chrome but the content area renders blank.
        // Use NSHostingView attached as `contentView` directly to
        // avoid the contentViewController lifecycle entirely.
        let initialRect = NSRect(x: 0, y: 0, width: 720, height: 480)
        let window = NSWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "SolidTerm Settings"
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: initialRect.size)
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SolidTermSettings")
        self.init(window: window)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}
