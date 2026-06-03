// Action enumeration for menu items + keybindings.
//
// Named `KeybindingAction` for historical reasons — the M6 ship
// originally drove these through a SwiftUI command-palette panel
// (deleted along with this comment block on 2026-05-19; the panel was
// disabled mid-2026-05 per dogfood-reported focus race). Actions still
// flow through `TerminalWindowController.dispatch(action:)` and
// the keybinding system in `KeybindingStore`; only the panel UI is
// gone.
//
// Keep cases stable + additive-friendly — `KeybindingStore` persists
// user customisations keyed on the raw values.

import AppKit

/// Actions exposed through the menu bar and the keybinding system.
public enum KeybindingAction: String, CaseIterable, Hashable {
    case openSettings
    case newWindow
    case closeWindow
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize
    case newTab
    case closeTab
    case prevTab
    case nextTab
    case selectTab1
    case selectTab2
    case selectTab3
    case selectTab4
    case selectTab5
    case selectTab6
    case selectTab7
    case selectTab8
    case selectTab9
    case openFindBar
    case switchTerminal
    case installShellIntegration

    /// User-facing label rendered in menus and the keybindings tab.
    public var title: String {
        switch self {
        case .openSettings: return "Open Settings…"
        case .newWindow: return "New Window"
        case .closeWindow: return "Close Window"
        case .increaseFontSize: return "Increase Font Size"
        case .decreaseFontSize: return "Decrease Font Size"
        case .resetFontSize: return "Reset Font Size"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .prevTab: return "Show Previous Tab"
        case .nextTab: return "Show Next Tab"
        case .selectTab1: return "Select Tab 1"
        case .selectTab2: return "Select Tab 2"
        case .selectTab3: return "Select Tab 3"
        case .selectTab4: return "Select Tab 4"
        case .selectTab5: return "Select Tab 5"
        case .selectTab6: return "Select Tab 6"
        case .selectTab7: return "Select Tab 7"
        case .selectTab8: return "Select Tab 8"
        case .selectTab9: return "Select Tab 9"
        case .openFindBar: return "Find…"
        case .switchTerminal: return "Switch Terminal…"
        case .installShellIntegration: return "Install Shell Integration…"
        }
    }

    /// Right-aligned keyboard-shortcut hint string. Empty for actions
    /// without a default binding.
    public var shortcut: String {
        switch self {
        case .openSettings: return "⌘,"
        case .newWindow: return "⌘N"
        case .closeWindow: return "⌘⇧W"
        case .increaseFontSize: return "⌘="
        case .decreaseFontSize: return "⌘-"
        case .resetFontSize: return "⌘0"
        case .newTab: return "⌘T"
        case .closeTab: return "⌘W"
        case .prevTab: return "⌘⇧["
        case .nextTab: return "⌘⇧]"
        case .selectTab1: return "⌘1"
        case .selectTab2: return "⌘2"
        case .selectTab3: return "⌘3"
        case .selectTab4: return "⌘4"
        case .selectTab5: return "⌘5"
        case .selectTab6: return "⌘6"
        case .selectTab7: return "⌘7"
        case .selectTab8: return "⌘8"
        case .selectTab9: return "⌘9"
        case .openFindBar: return "⌘F"
        case .switchTerminal: return "⌘⇧O"
        case .installShellIntegration: return ""
        }
    }

    public var keywords: [String] {
        switch self {
        case .openSettings: return ["settings", "preferences", "prefs", "config"]
        case .newWindow: return ["new", "window", "open"]
        case .closeWindow: return ["close", "window", "quit"]
        case .increaseFontSize: return ["font", "zoom", "in", "bigger", "larger"]
        case .decreaseFontSize: return ["font", "zoom", "out", "smaller"]
        case .resetFontSize: return ["font", "zoom", "reset", "default"]
        case .newTab: return ["new", "tab", "open"]
        case .closeTab: return ["close", "tab"]
        case .prevTab: return ["previous", "prev", "tab", "back"]
        case .nextTab: return ["next", "tab", "forward"]
        case .selectTab1: return ["tab", "1", "select"]
        case .selectTab2: return ["tab", "2", "select"]
        case .selectTab3: return ["tab", "3", "select"]
        case .selectTab4: return ["tab", "4", "select"]
        case .selectTab5: return ["tab", "5", "select"]
        case .selectTab6: return ["tab", "6", "select"]
        case .selectTab7: return ["tab", "7", "select"]
        case .selectTab8: return ["tab", "8", "select"]
        case .selectTab9: return ["tab", "9", "select"]
        case .openFindBar: return ["find", "search", "scrollback", "grep"]
        case .switchTerminal:
            return [
                "switch", "terminal", "window", "tab", "jump", "go",
                "picker", "palette", "fuzzy",
            ]
        case .installShellIntegration:
            return [
                "shell", "integration", "install", "osc 133", "zsh", "bash",
                "fish", "hooks",
            ]
        }
    }

    /// M7-5: 1-9 index for selectTabN actions; nil for non-tab-index actions.
    public var tabIndex: Int? {
        switch self {
        case .selectTab1: return 1
        case .selectTab2: return 2
        case .selectTab3: return 3
        case .selectTab4: return 4
        case .selectTab5: return 5
        case .selectTab6: return 6
        case .selectTab7: return 7
        case .selectTab8: return 8
        case .selectTab9: return 9
        default: return nil
        }
    }

    /// Stable accessibility identifier for UI tests + accessibility.
    public var accessibilityId: String { "keybinding.\(rawValue)" }

    /// S4: grouping bucket for the Settings → Keybindings tab. Keeps
    /// the flat-22 list scannable by clustering related actions
    /// (Window, Tabs, Font, …) under a single header.
    public enum Category: String, CaseIterable {
        case app = "App"
        case window = "Window"
        case tabs = "Tabs"
        case font = "Font"
        case find = "Find"
        case shell = "Shell"
    }

    public var category: Category {
        switch self {
        case .openSettings: return .app
        case .newWindow, .closeWindow, .switchTerminal: return .window
        case .newTab, .closeTab, .prevTab, .nextTab,
             .selectTab1, .selectTab2, .selectTab3,
             .selectTab4, .selectTab5, .selectTab6,
             .selectTab7, .selectTab8, .selectTab9:
            return .tabs
        case .increaseFontSize, .decreaseFontSize, .resetFontSize:
            return .font
        case .openFindBar: return .find
        case .installShellIntegration: return .shell
        }
    }
}
