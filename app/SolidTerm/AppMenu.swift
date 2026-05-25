// Implements spec/swift-app-modules.md §Menu Bar and Services.
// Programmatic menu bar — no MainMenu.xib.
//
// M6-5: app-action menu items (Preferences, New Window, Close Window,
// Find…) draw their `keyEquivalent` from `KeybindingStore.shared`
// instead of hardcoding strings. Items are rebuilt when the store
// publishes a change so user-edited bindings take effect without an
// app restart.

import AppKit
import Combine

@MainActor
enum AppMenu {
    /// Cancellable for `KeybindingStore.shared.$effective` observation.
    /// Static so the subscription survives the duration of the app.
    private static var storeSubscription: AnyCancellable?

    static func install() {
        rebuild()
        // Rebuild the menu when the user changes a binding via the
        // Settings → Keybindings tab. KeybindingStore publishes on the
        // main thread; rebuild() is MainActor-isolated.
        storeSubscription = KeybindingStore.shared.$effective
            .dropFirst()  // skip initial value (just installed)
            .sink { _ in
                Task { @MainActor in rebuild() }
            }
    }

    /// Build (or rebuild) the entire main menu. Called on launch and
    /// on every KeybindingStore change.
    static func rebuild() {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(windowMenuItem())
        mainMenu.addItem(helpMenuItem())
        NSApp.mainMenu = mainMenu
    }

    /// Add a menu item whose key equivalent is sourced from
    /// `KeybindingStore.shared` for the given action. If the store
    /// has no binding (user disabled the action), the item is added
    /// with no key equivalent.
    @discardableResult
    private static func addItem(
        in menu: NSMenu, title: String, action: Selector,
        binding: KeybindingAction
    ) -> NSMenuItem {
        let (keyEq, mask) = KeybindingStore.shared
            .menuKeyEquivalent(for: binding)
        let item = menu.addItem(
            withTitle: title, action: action,
            keyEquivalent: keyEq)
        if !mask.isEmpty {
            item.keyEquivalentModifierMask = mask
        }
        return item
    }

    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "SolidTerm")
        let appName = ProcessInfo.processInfo.processName

        menu.addItem(
            withTitle: "About \(appName)",
            action: #selector(AppDelegate.showAboutPanel(_:)),
            keyEquivalent: "")
        menu.addItem(.separator())
        // M5-2 — Preferences opens `SettingsWindowController` per
        // spec/swift-app-modules.md §Settings Window. M6-5: shortcut
        // sourced from KeybindingStore.
        addItem(
            in: menu, title: "Preferences…",
            action: #selector(AppDelegate.openSettingsWindow),
            binding: .openSettings)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        let hideOthers = menu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    private static func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")

        addItem(
            in: menu, title: "New Window",
            action: #selector(AppDelegate.openNewWindow),
            binding: .newWindow)
        // M7-5 — New Tab adds a tab to the key window's NSWindowTabGroup
        // (or opens a fresh window when there's no key window).
        addItem(
            in: menu, title: "New Tab",
            action: #selector(AppDelegate.openNewTab(_:)),
            binding: .newTab)
        // ⌘W → close the active tab. AppKit's `performClose(_:)` closes
        // the window when only one tab is open, so this is the natural
        // single-binding for the merged "close tab / close window if
        // last" behaviour the brief calls out.
        addItem(
            in: menu, title: "Close Tab",
            action: #selector(NSWindow.performClose(_:)),
            binding: .closeTab)
        // ⌘⇧W → close the entire window (every tab in the group).
        addItem(
            in: menu, title: "Close Window",
            action: #selector(
                TerminalWindowController.closeWindowAndAllTabs(_:)),
            binding: .closeWindow)

        menu.addItem(.separator())

        // M7-2 — ⌘F find-in-scrollback. Routes through KeybindingStore
        // so the user can rebind via Settings → Keybindings.
        addItem(
            in: menu, title: "Find…",
            action: #selector(TerminalWindowController.toggleFindBar(_:)),
            binding: .openFindBar)

        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        // "Paste (Plain)" — ⌘⇧V — bypasses bracketed-paste wrapping for
        // TUIs that don't honor DECSET 2004 (e.g. Ink-based CLIs like
        // Claude Code) running under shells that did set the mode. The
        // selector is `pastePlain(_:)` on `TerminalSurfaceView`; menu
        // validation lights it up iff the pasteboard carries a string.
        // Hardcoded key equivalent for the MVP — KeybindingStore wiring
        // can fold this in later without disturbing the menu structure.
        let pastePlain = menu.addItem(
            withTitle: "Paste (Plain)",
            action: #selector(TerminalSurfaceView.pastePlain(_:)),
            keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a")

        item.submenu = menu
        return item
    }

    /// View menu — zoom-style font-size controls (M7-3). These post
    /// to the responder chain via `dispatch(action:)` selector so
    /// every TerminalWindowController in the app picks up the active
    /// keystroke; the FontSettings store is process-wide so a single
    /// invocation updates every renderer.
    private static func viewMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        addItem(
            in: menu, title: "Increase Font Size",
            action: #selector(TerminalWindowController.increaseFontSize(_:)),
            binding: .increaseFontSize)
        addItem(
            in: menu, title: "Decrease Font Size",
            action: #selector(TerminalWindowController.decreaseFontSize(_:)),
            binding: .decreaseFontSize)
        addItem(
            in: menu, title: "Reset Font Size",
            action: #selector(TerminalWindowController.resetFontSize(_:)),
            binding: .resetFontSize)
        item.submenu = menu
        return item
    }

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")

        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        menu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: "")
        menu.addItem(.separator())
        // M7-5 — Tab navigation. AppKit's `selectNextTab:` /
        // `selectPreviousTab:` selectors are window-local and the
        // responder chain dispatches them to the focused tab's window.
        addItem(
            in: menu, title: "Show Previous Tab",
            action: #selector(NSWindow.selectPreviousTab(_:)),
            binding: .prevTab)
        addItem(
            in: menu, title: "Show Next Tab",
            action: #selector(NSWindow.selectNextTab(_:)),
            binding: .nextTab)
        menu.addItem(.separator())
        // ⌘1..⌘9 — select tab by index. Each item routes through
        // `TerminalWindowController.selectTabN(_:)` (one selector per
        // index so the responder-chain dispatch maps cleanly without a
        // tag/sender lookup).
        let tabSelectors: [(KeybindingAction, Selector)] = [
            (.selectTab1, #selector(TerminalWindowController.selectTab1(_:))),
            (.selectTab2, #selector(TerminalWindowController.selectTab2(_:))),
            (.selectTab3, #selector(TerminalWindowController.selectTab3(_:))),
            (.selectTab4, #selector(TerminalWindowController.selectTab4(_:))),
            (.selectTab5, #selector(TerminalWindowController.selectTab5(_:))),
            (.selectTab6, #selector(TerminalWindowController.selectTab6(_:))),
            (.selectTab7, #selector(TerminalWindowController.selectTab7(_:))),
            (.selectTab8, #selector(TerminalWindowController.selectTab8(_:))),
            (.selectTab9, #selector(TerminalWindowController.selectTab9(_:))),
        ]
        for (binding, selector) in tabSelectors {
            addItem(
                in: menu,
                title: binding.title,
                action: selector,
                binding: binding)
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "")

        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    private static func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        menu.addItem(
            withTitle: "SolidTerm Help",
            action: #selector(NSApplication.showHelp(_:)),
            keyEquivalent: "?")
        item.submenu = menu
        NSApp.helpMenu = menu
        return item
    }
}
