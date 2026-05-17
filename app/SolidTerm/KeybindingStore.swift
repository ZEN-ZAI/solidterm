// M6-5 KeybindingStore — load/save ~/.solidterm/keybindings.json,
// resolve `CommandPaletteAction` cases against effective bindings.
//
// Authoritative spec: spec/keyboard-system.md (M6 pre-flight pass 4
// finalized 2026-05-10) + research/20-m6-plan.md §M6-5.
//
// Scope (M6 ship slice):
// - Defaults table for the 8 `CommandPaletteAction` cases shipped in M6-1
// - JSON load/save with malformed-fallback (warn + use defaults, don't crash)
// - Conflict semantics: last-wins in `bindings`; `disabled` beats
//   `bindings`; user file beats built-ins (load order: defaults → user)
// - Reserved-range validation: cmd+1-9 (Phase 2 tabByIndex),
//   cmd+shift+[/] (Phase 2 prevTab/nextTab), cmd+alt+shift+[/]
//   (M6+ jumpToErrorBlock) — warn + skip at JSON load; UI capture
//   blocks save at the editor level
// - Unknown action strings: warn + skip per spec line 175
// - Chord syntax (`cmd+k cmd+t`) decode-but-runtime-skip per Phase 2
//   FocusStackManager dependency
//
// Out of scope (deferred to Phase 2):
// - Chord runtime dispatch (1.5s timer + leader fallback) — needs
//   FocusStackManager
// - Per-action scope resolution (active pane > window > global) —
//   M6 has only global-scope actions
// - Find/Find-Next, splitPane*, focusPane*, zoom*, toggleNativeMode,
//   etc. (the rest of spec/keyboard-system.md §App-action keybindings) —
//   not yet in `CommandPaletteAction` enum, M3+/Phase-2

import AppKit
import Foundation

/// File-format DTOs for `~/.solidterm/keybindings.json`. Keep these as
/// raw structs (not coupled to `CommandPaletteAction`) so unknown
/// actions and reserved-range entries can be inspected pre-validation.
public struct KeybindingsFile: Codable {
    public var bindings: [Entry] = []
    public var disabled: [String] = []

    public struct Entry: Codable {
        public var key: String
        public var action: String

        public init(key: String, action: String) {
            self.key = key
            self.action = action
        }
    }

    public init(bindings: [Entry] = [], disabled: [String] = []) {
        self.bindings = bindings
        self.disabled = disabled
    }

    /// Both top-level fields are optional in the on-disk file —
    /// `{ "bindings": [...] }` without `disabled` is valid (and vice
    /// versa). Synthesized `Codable` would mark missing keys as a
    /// decode error, so we hand-roll the decoder; encoder stays
    /// synthesized.
    private enum CodingKeys: String, CodingKey {
        case bindings, disabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.bindings = (try? c.decode([Entry].self, forKey: .bindings)) ?? []
        self.disabled = (try? c.decode([String].self, forKey: .disabled)) ?? []
    }
}

/// Resolved (effective) binding from a `CommandPaletteAction` case to
/// a normalized key string (e.g. "cmd+b"). Suitable for AppMenu's
/// `keyEquivalent` + modifier-mask wiring.
public struct EffectiveBinding: Equatable {
    public let action: CommandPaletteAction
    /// Normalized key string. ASCII-only, lowercased mods, single
    /// stroke (chord support pending per file-header note).
    public let key: String
}

/// Diagnostic emitted during JSON load. Surfaced to UI for "warning
/// chip" rendering; logged to NSLog for debug visibility.
public enum KeybindingDiagnostic: Equatable {
    case unknownAction(action: String, key: String)
    case reservedKey(key: String, action: String)
    case chordUnsupported(key: String, action: String)
    case duplicateKey(key: String, kept: String, dropped: String)
    case malformedFile(reason: String)
}

@MainActor
public final class KeybindingStore: ObservableObject {
    /// Process-wide singleton — AppMenu, KeybindingsTab, and the
    /// (Phase 2) FocusStackManager all read through this. Lazy so
    /// tests can construct ad-hoc stores via `init(fileURL:)`.
    public static let shared = KeybindingStore(
        fileURL: defaultFileURL())

    /// Active effective bindings — defaults overlaid by user file
    /// minus disabled keys.
    @Published public private(set) var effective:
        [CommandPaletteAction: String] = [:]
    /// Diagnostics emitted during the most recent load. UI surfaces
    /// these as warning chips per spec/keyboard-system.md §Conflict.
    @Published public private(set) var diagnostics:
        [KeybindingDiagnostic] = []

    private let fileURL: URL
    private static let chordSeparator = " "

    public init(fileURL: URL) {
        self.fileURL = fileURL
        reload()
    }

    /// Default `~/.solidterm/keybindings.json` path. Static so tests
    /// can resolve the production path without touching the singleton.
    public static func defaultFileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            ".solidterm/keybindings.json", isDirectory: false)
    }

    // MARK: - Defaults table

    /// Built-in defaults for `CommandPaletteAction` cases.
    /// Source-of-truth pinned to spec/keyboard-system.md.
    /// M7-5 added the tab-surface bindings (newTab, closeTab, prevTab,
    /// nextTab, selectTab1..9) — this dropped them out of the reserved
    /// range and pushed `closeWindow` to ⌘⇧W so ⌘W goes to closeTab
    /// (AppKit's `performClose:` does the right "last tab → close
    /// window" thing in either case).
    public static let defaults: [CommandPaletteAction: String] = [
        // openCommandPalette: ⌘K binding hidden 2026-05-11 per user
        // dogfood report (first-invocation works, subsequent invocations
        // wedge in some focus configurations). Action stays in the enum
        // so the dispatcher + selector wiring re-enable in one block;
        // when the focus race is understood, restore: `.openCommandPalette: "cmd+k",`
        .openSettings: "cmd+,",
        .newWindow: "cmd+n",
        .closeWindow: "cmd+shift+w",
        .increaseFontSize: "cmd+=",
        .decreaseFontSize: "cmd+-",
        .resetFontSize: "cmd+0",
        .newTab: "cmd+t",
        .closeTab: "cmd+w",
        .prevTab: "cmd+shift+[",
        .nextTab: "cmd+shift+]",
        .selectTab1: "cmd+1",
        .selectTab2: "cmd+2",
        .selectTab3: "cmd+3",
        .selectTab4: "cmd+4",
        .selectTab5: "cmd+5",
        .selectTab6: "cmd+6",
        .selectTab7: "cmd+7",
        .selectTab8: "cmd+8",
        .selectTab9: "cmd+9",
        .openFindBar: "cmd+f",
        // Palette-only — rarely invoked, no muscle-memory hotkey.
        .installShellIntegration: "ctrl+alt+i",
    ]

    // MARK: - Reserved ranges

    /// Keys reserved for future bindings; M6+ must not bind these,
    /// JSON loads warn + skip, UI capture blocks save.
    /// - cmd+alt+shift+[ / cmd+alt+shift+]: M6+ jumpToPrev/NextErrorBlock
    ///   per spec lines 54-55
    ///
    /// M7-5 lifted the cmd+1..9 + cmd+shift+[/] reservations — those
    /// are now live tab bindings (selectTabN / prevTab / nextTab).
    public static func isReserved(_ key: String) -> Bool {
        let normalized = normalizeKey(key)
        // cmd+alt+shift+[ / cmd+alt+shift+]
        if normalized == "cmd+alt+shift+["
            || normalized == "cmd+alt+shift+]"
        {
            return true
        }
        return false
    }

    // MARK: - Public API

    /// Resolve a `CommandPaletteAction` to its current effective key
    /// string (e.g. "cmd+b"), or `nil` if disabled / unbound.
    public func lookup(_ action: CommandPaletteAction) -> String? {
        effective[action]
    }

    /// Reload from disk. Called automatically on init; KeybindingsTab
    /// triggers it after save() so observers refresh.
    public func reload() {
        var diag: [KeybindingDiagnostic] = []
        var table = Self.defaults

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            self.effective = table
            self.diagnostics = diag
            return
        }

        let parsed: KeybindingsFile
        do {
            let data = try Data(contentsOf: fileURL)
            parsed = try JSONDecoder().decode(
                KeybindingsFile.self, from: data)
        } catch {
            diag.append(.malformedFile(reason: error.localizedDescription))
            NSLog("KeybindingStore: malformed keybindings.json — falling "
                + "back to defaults. Reason: \(error)")
            self.effective = table
            self.diagnostics = diag
            return
        }

        // Pre-compute disabled set so the binding loop can consult it
        // when restoring a default for an evicted action.
        let disabledSet = Set(parsed.disabled.map(Self.normalizeKey))

        // Apply user bindings in order; track keys for duplicate detection.
        var lastForKey: [String: CommandPaletteAction] = [:]
        for entry in parsed.bindings {
            let normalizedKey = Self.normalizeKey(entry.key)
            // Chord (space-separated) — decode but skip runtime
            if normalizedKey.contains(Self.chordSeparator) {
                diag.append(.chordUnsupported(
                    key: entry.key, action: entry.action))
                continue
            }
            // Unknown action — warn + skip
            guard let action = CommandPaletteAction(rawValue: entry.action)
            else {
                diag.append(.unknownAction(
                    action: entry.action, key: entry.key))
                continue
            }
            // Reserved key — warn + skip
            if Self.isReserved(normalizedKey) {
                diag.append(.reservedKey(
                    key: entry.key, action: entry.action))
                continue
            }
            // Duplicate-key → last-wins; emit diagnostic
            if let prev = lastForKey[normalizedKey] {
                diag.append(.duplicateKey(
                    key: normalizedKey,
                    kept: action.rawValue,
                    dropped: prev.rawValue))
            }
            // User binding overrides default for this action. If
            // another action currently holds this key, evict it; if
            // the evicted action has a default that's still free,
            // restore it to its default rather than dropping it
            // entirely (matches user expectation: a user binding
            // displacing another user binding shouldn't unbind the
            // displaced action).
            let evictees = table.filter { $0.key != action && $0.value == normalizedKey }
            for (a, _) in evictees {
                table.removeValue(forKey: a)
                if let def = Self.defaults[a],
                    def != normalizedKey,
                    !table.values.contains(def),
                    !disabledSet.contains(def)
                {
                    table[a] = def
                }
            }
            table[action] = normalizedKey
            lastForKey[normalizedKey] = action
        }

        // `disabled` is processed after `bindings` per spec line 189.
        // Suppress any action whose effective key matches a disabled entry.
        for (action, key) in table where disabledSet.contains(key) {
            table.removeValue(forKey: action)
        }

        self.effective = table
        self.diagnostics = diag
    }

    /// Atomic write of `bindings` + `disabled` to the user file.
    /// Caller is expected to validate (capture-button enforces
    /// `!isReserved`); this call writes whatever's handed in. Throws
    /// on filesystem error so the UI can surface it.
    public func save(
        bindings: [KeybindingsFile.Entry], disabled: [String]
    ) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let payload = KeybindingsFile(
            bindings: bindings, disabled: disabled)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: .atomic)
        reload()
    }

    /// Reset all bindings to built-in defaults — deletes the user
    /// file. Idempotent; missing file is fine.
    public func resetAllToDefaults() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        reload()
    }

    /// Reset a single action to its default key. Implemented by
    /// rewriting the file without that action's user-override entry.
    public func resetActionToDefault(
        _ action: CommandPaletteAction
    ) throws {
        // Read current file, drop entries pointing to this action,
        // rewrite. Disabled list survives.
        var current: KeybindingsFile = .init()
        if let data = try? Data(contentsOf: fileURL),
            let parsed = try? JSONDecoder().decode(
                KeybindingsFile.self, from: data)
        {
            current = parsed
        }
        current.bindings.removeAll { $0.action == action.rawValue }
        try save(bindings: current.bindings, disabled: current.disabled)
    }

    // MARK: - Key normalization

    /// Lowercase, sort modifiers into canonical order
    /// (cmd, ctrl, alt, shift), preserve chord separators (single
    /// spaces). Per spec/keyboard-system.md §"`key` field grammar":
    /// "case-insensitive", "Modifier order within a stroke is not
    /// enforced" — so the store imposes a canonical order for
    /// internal equality + lookup.
    public static func normalizeKey(_ raw: String) -> String {
        let strokes = raw.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        return strokes.map(normalizeStroke).joined(separator: " ")
    }

    private static func normalizeStroke(_ stroke: String) -> String {
        let parts = stroke.split(separator: "+", omittingEmptySubsequences: true)
            .map(String.init)
        // Last part is the key; everything else is a modifier.
        guard parts.count >= 1 else { return stroke }
        let key = parts.last ?? ""
        let rawMods = parts.dropLast()
        let modOrder: [String] = ["cmd", "ctrl", "alt", "shift"]
        let mods = modOrder.filter { rawMods.contains($0) }
        if mods.isEmpty { return key }
        return mods.joined(separator: "+") + "+" + key
    }
}

// MARK: - AppKit bridge

extension KeybindingStore {
    /// Resolve an action's effective key into an `NSMenuItem`-shaped
    /// `(keyEquivalent, modifierMask)` tuple. Returns `("", [])` if
    /// the action is disabled or unbound. AppMenu calls this when
    /// constructing menu items; observers rebuild on store change.
    public func menuKeyEquivalent(
        for action: CommandPaletteAction
    ) -> (String, NSEvent.ModifierFlags) {
        guard let key = lookup(action) else { return ("", []) }
        return Self.parseToMenuKey(key)
    }

    /// Convert a normalized key string to an AppKit menu binding.
    /// Examples:
    ///   "cmd+k"        → ("k", [.command])
    ///   "cmd+shift+c"  → ("C", [.command, .shift])  // uppercase + shift mask
    ///   "cmd+,"        → (",", [.command])
    /// AppKit's idiom for "shifted letter" is uppercase-letter + .shift
    /// modifier (see AppMenu.swift "Copy Block" comment).
    public static func parseToMenuKey(
        _ normalized: String
    ) -> (String, NSEvent.ModifierFlags) {
        let parts = normalized.split(separator: "+",
            omittingEmptySubsequences: true).map(String.init)
        guard let key = parts.last else { return ("", []) }
        let mods = Set(parts.dropLast())
        var mask: NSEvent.ModifierFlags = []
        if mods.contains("cmd") { mask.insert(.command) }
        if mods.contains("ctrl") { mask.insert(.control) }
        if mods.contains("alt") { mask.insert(.option) }
        let hasShift = mods.contains("shift")
        if hasShift { mask.insert(.shift) }
        // AppKit: shifted letter = uppercase keyEquivalent.
        let keyEq: String
        if hasShift, key.count == 1, let c = key.first, c.isLetter {
            keyEq = String(c).uppercased()
        } else {
            keyEq = key
        }
        return (keyEq, mask)
    }
}
