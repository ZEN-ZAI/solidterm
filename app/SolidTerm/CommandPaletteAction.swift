// M6-1 Command Palette — action enumeration.
//
// Hard-coded list of built-in palette actions. M6 ship is enum-based per
// research/20-m6-plan.md §M6-1; the spec's full `PaletteEntry`/`CommandKind`/
// `FocusStackManager` surface (plugin sync, source badges, recency, sectioning,
// `prompt(allowedTools)` dispatch) is M3+/Phase-2 work — see
// spec/swift-app-modules.md §Command Palette "live Claude-command sync".
//
// M6-5 Keybinding customization binds `CommandPaletteAction` cases by
// identity — keep cases stable + additive-friendly.
//
// M7-5: cmd+1..9 + cmd+shift+[/] are now LIVE bindings for the tab
// surface (selectTabN / prevTab / nextTab). The reserved-range entries
// in `KeybindingStore.isReserved` drop accordingly. Reserved-but-unused:
// cmd+alt+shift+[/] (M6+ jumpToError* — still pending).

import AppKit

/// Built-in actions exposed by the command palette. The label appears in
/// the palette row; `keywords` extends fuzzy-match coverage past the
/// label (e.g. "prefs" → openSettings).
public enum CommandPaletteAction: String, CaseIterable, Hashable {
    case openCommandPalette
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
    case installShellIntegration

    /// User-facing label rendered in the palette result row.
    public var title: String {
        switch self {
        case .openCommandPalette: return "Open Command Palette"
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
        case .installShellIntegration: return "Install Shell Integration…"
        }
    }

    /// Right-aligned keyboard-shortcut hint string. Empty for actions
    /// without a default binding.
    public var shortcut: String {
        switch self {
        case .openCommandPalette: return "⌘K"
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
        case .installShellIntegration: return ""
        }
    }

    public var keywords: [String] {
        switch self {
        case .openCommandPalette: return ["palette", "command", "actions"]
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
    public var accessibilityId: String { "palette.\(rawValue)" }

    /// Single haystack the fuzzy matcher scores against. Title +
    /// keywords joined and lowercased once.
    var searchHaystack: String {
        ([title] + keywords).joined(separator: " ").lowercased()
    }

    /// Actions surfaced in the palette UI. `.toggleLeftSidebar` is
    /// back in the visible set now that the M3/M4 unhide re-exposes
    /// the Sessions / Subagents / Library / CLAUDE.md viewer surfaces.
    public static var paletteVisible: [CommandPaletteAction] {
        let hidden: Set<CommandPaletteAction> = [
            // The palette doesn't list itself — especially while ⌘K
            // is unbound (2026-05-11 dogfood report).
            .openCommandPalette,
        ]
        return allCases.filter { !hidden.contains($0) }
    }
}

// MARK: - Fuzzy match

/// Subsequence + prefix-bonus fuzzy matcher. Returns nil if `query` is
/// not a subsequence of `haystack` (case-insensitive). Returns a score
/// in [0, 1) where higher = better match. Empty query matches everything
/// at score 0.0 (caller falls back to original ordering).
///
/// Algorithm:
/// - subsequence walk; bail on first non-match
/// - +1 bonus per consecutive run; +1 if the match starts at position 0
/// - score = bonus / (haystack.count + bonus_max) — keeps in [0, 1)
///
/// Cheap, no allocations, deterministic. Good enough for ~10 entries.
public enum CommandPaletteFuzzy {
    /// Returns `nil` if `query` is not a subsequence of `haystack`.
    /// Otherwise returns a score in `[0, 1]`. Empty query → 0.
    ///
    /// Score = (runFrac + prefixBonus + wordBonus - lengthPenalty) / 2.5,
    /// clamped to [0, 1]:
    /// - runFrac = bestRun / query.count — rewards contiguous matching
    ///   ("set" inside "settings" beats "set" scattered as s,e,t across
    ///   "close window quit")
    /// - +1.0 prefix bonus when haystack[0] == query[0]
    /// - +0.5 word-boundary bonus when query[0] follows a space
    /// - -0.1 × (haystack.count / 100) length penalty (small —
    ///   contiguity is the dominant signal)
    public static func score(query: String, haystack: String) -> Double? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let h = Array(haystack.lowercased())
        var qi = 0
        var run = 0
        var bestRun = 0
        var prefixHit = false
        var wordBoundaryHit = false
        var prevCharWasSpace = true
        for (hi, hc) in h.enumerated() {
            guard qi < q.count else { break }
            if hc == q[qi] {
                if qi == 0 {
                    if hi == 0 { prefixHit = true }
                    if prevCharWasSpace { wordBoundaryHit = true }
                }
                run += 1
                bestRun = max(bestRun, run)
                qi += 1
            } else {
                run = 0
            }
            prevCharWasSpace = (hc == " ")
        }
        guard qi == q.count else { return nil }
        let runFrac = Double(bestRun) / Double(q.count)
        let prefixBonus = prefixHit ? 1.0 : 0.0
        let wordBonus = wordBoundaryHit ? 0.5 : 0.0
        let lengthPenalty = 0.1 * Double(h.count) / 100.0
        let raw = runFrac + prefixBonus + wordBonus - lengthPenalty
        return max(0, min(1, raw / 2.5))
    }

    /// Filter + sort `actions` against `query`. Empty query returns
    /// `actions` unchanged.
    public static func filter(
        _ actions: [CommandPaletteAction], query: String
    ) -> [CommandPaletteAction] {
        if query.isEmpty { return actions }
        let scored: [(CommandPaletteAction, Double)] = actions.compactMap {
            action in
            guard let s = score(
                query: query, haystack: action.searchHaystack)
            else { return nil }
            return (action, s)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.title < rhs.0.title
            }
            .map(\.0)
    }
}
