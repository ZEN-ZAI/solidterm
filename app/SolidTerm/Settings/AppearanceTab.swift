// Appearance tab — bundles M6-2 (file-path click) + M6-4a (theme picker).
//
// **Authorship note**: this file is the canonical AppearanceTab. M6-2's
// `worktree-m6-2-filepath` (`409f1a8`) introduced the file with only
// the file-path click section; M6-4a (this branch) lands first to main
// with both sections bundled. Consolidation rebase will conflict-resolve
// cleanly — same author (swift-builder-2), same file shape, no
// concat-merge friction (decided by team-lead-2 over a separate-section
// alternative).
//
// Replaces the `StubTabView` registration in `SettingsTab.defaults`
// with two real sections:
// - File-path click: M6-2's editor-picker (Default / VS Code / Cursor /
//   Sublime Text / Zed / Other...) + detection toggle.
// - Theme: M6-4a's mode picker (System / Light / Dark / Zenzai Dark /
//   Zenzai Light). Light variants resolve to dark tokens with a
//   one-shot startup warning until M6-4b lands the spec-keeper's
//   light derivation per `spec/design-tokens.md:119-126`'s explicit
//   gap notice.
//
// Persistence: per-feature `UserDefaults` keys, matching the existing
// M5 pattern (sidebar visibility, RateLimitHUD) — no centralized
// SettingsStore abstraction yet. Surfaces graduate to a store when a
// third feature needs to share state.

import AppKit
import SwiftUI

@MainActor
struct AppearanceTab: View {
    /// Persistence key namespace for the file-path click section.
    /// Surfaces also referenced by the renderer hover-state code so
    /// they stay in lockstep.
    enum Keys {
        static let editor = "solidterm.filePathClick.editor"
        static let customCommand = "solidterm.filePathClick.customCommand"
        static let detectionEnabled = "solidterm.filePathClick.detectionEnabled"
    }

    @AppStorage(Keys.editor) private var editorRaw: String = EditorChoice.defaultOpen.rawValue
    @AppStorage(Keys.customCommand) private var customCommand: String = ""
    @AppStorage(Keys.detectionEnabled) private var detectionEnabled: Bool = true
    /// M7-4: opt-in slim left-margin accent rule at OSC 133 prompt
    /// rows. Default `false` preserves the M5.5 dogfood "no stripes"
    /// out-of-the-box behavior.
    @AppStorage(Theme.OSC133.userDefaultsKey) private var osc133AccentEnabled: Bool = false

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var fontSettings = FontSettings.shared
    @ObservedObject private var themeFiles = ThemeFileStore.shared

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.three) {
                    themeSection
                    Divider()
                    fontSection
                    Divider()
                    commandMarkersSection
                    Divider()
                    filePathSection
                }
                .padding(Theme.Spacing.three)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    // MARK: M7-3 — Font section

    /// System monospace fonts surfaced in the picker. We list the
    /// monospaced subset rather than the full system font catalog
    /// because variable-width fonts visibly break the cell grid.
    /// `fixedPitch` traits filter is unreliable on some installs, so
    /// we hand-curate the common-on-macOS picks plus the user's
    /// current selection (so a custom family from `defaults write`
    /// still appears).
    private static let curatedMonospaceFonts: [String] = [
        "Menlo-Regular",
        "Monaco",
        "Courier",
        "Courier New",
        "SF Mono Regular",
        "PT Mono",
        "Andale Mono",
    ]

    private var availableFonts: [String] {
        var names = Self.curatedMonospaceFonts
        if !names.contains(fontSettings.family) {
            names.append(fontSettings.family)
        }
        return names
    }

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.two) {
            Text("Font").font(.headline)
            Text(
                "Use ⌘+ / ⌘- to adjust size on the fly. ⌘0 resets to the default."
            )
            .font(.callout)
            .foregroundColor(.secondary)
            Picker(
                "Family:",
                selection: Binding(
                    get: { fontSettings.family },
                    set: { fontSettings.setFamily($0) }
                )
            ) {
                ForEach(availableFonts, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            HStack {
                Text("Size:")
                Stepper(
                    value: Binding(
                        get: { fontSettings.size },
                        set: { fontSettings.setSize($0) }
                    ),
                    in: FontSettings.minSize...FontSettings.maxSize,
                    step: 1
                ) {
                    Text("\(Int(fontSettings.size)) pt")
                        .monospacedDigit()
                }
            }
            Toggle(
                "Enable ligatures (font must support them)",
                isOn: Binding(
                    get: { fontSettings.ligatures },
                    set: { fontSettings.setLigatures($0) }
                ))
        }
    }

    // MARK: M6-4a — Theme section

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.two) {
            Text("Theme").font(.headline)
            Text(
                "Themes live in ~/.config/solidterm/themes/*.toml — edit any file and the change applies live. Built-in modes are still available below."
            )
            .font(.callout)
            .foregroundColor(.secondary)
            Picker(
                "Theme file:",
                selection: Binding(
                    get: { themeFiles.current?.name ?? "" },
                    set: { name in
                        themeFiles.setActive(name.isEmpty ? nil : name)
                    }
                )
            ) {
                Text("(use built-in mode below)").tag("")
                ForEach(
                    themeFiles.available.keys.sorted(), id: \.self
                ) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            Picker(
                "Built-in mode:",
                selection: Binding(
                    get: { themeManager.mode },
                    set: { themeManager.setMode($0) }
                )
            ) {
                ForEach(Theme.Mode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .disabled(themeFiles.current != nil)
        }
    }

    // MARK: M7-4 — Command markers section

    private var commandMarkersSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.two) {
            Text("Command markers").font(.headline)
            Text(
                "Show a slim left-margin accent at each shell prompt, color-coded by exit status (running / success / error). Requires shell integration (OSC 133); off by default."
            )
            .font(.callout)
            .foregroundColor(.secondary)
            Toggle(
                "Show command markers",
                isOn: $osc133AccentEnabled)
        }
    }

    // MARK: M6-2 — File-path click section

    private var filePathSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.two) {
            Text("File-path click").font(.headline)
            Text(
                "Hold ⌘ and click a file path in the terminal to open it. Detection is filesystem-confirmed — paths only highlight when the file exists."
            )
            .font(.callout)
            .foregroundColor(.secondary)
            Toggle(
                "Detect file paths under the cursor",
                isOn: $detectionEnabled)
            Picker("Open files in:", selection: $editorRaw) {
                ForEach(EditorChoice.fixedChoices, id: \.rawValue) { choice in
                    Text(choice.label).tag(choice.rawValue)
                }
                Text("Other…").tag(EditorChoice.other.rawValue)
            }
            .pickerStyle(.menu)
            .disabled(!detectionEnabled)
            if EditorChoice(rawValue: editorRaw) == .other {
                TextField(
                    "CLI command (e.g. /usr/local/bin/mate)",
                    text: $customCommand
                )
                .textFieldStyle(.roundedBorder)
                .disabled(!detectionEnabled)
            }
        }
    }
}

/// Editor choices for `⌘+click`. `rawValue` is the persisted token in
/// `UserDefaults`; `command` is the CLI argv[0] handed to `Process` at
/// click time. `defaultOpen` uses the macOS `open(1)` launcher (which
/// honors the user's per-extension default app). M6-2 contract; lives
/// here so M6-2's renderer hover-state code can resolve the configured
/// editor from `UserDefaults` without coupling to a settings panel.
enum EditorChoice: String, CaseIterable {
    case defaultOpen
    case vscode
    case cursor
    case sublime
    case zed
    case other

    static let fixedChoices: [EditorChoice] = [
        .defaultOpen, .vscode, .cursor, .sublime, .zed,
    ]

    var label: String {
        switch self {
        case .defaultOpen: return "Default (open)"
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .sublime: return "Sublime Text"
        case .zed: return "Zed"
        case .other: return "Other…"
        }
    }

    /// CLI argv[0] for `Process.launchPath`. `nil` for `.other` because
    /// the caller reads the `customCommand` UserDefault instead.
    var command: String? {
        switch self {
        case .defaultOpen: return "/usr/bin/open"
        case .vscode: return "code"
        case .cursor: return "cursor"
        case .sublime: return "subl"
        case .zed: return "zed"
        case .other: return nil
        }
    }

    /// Resolve the configured editor from `UserDefaults`. Returns the
    /// argv[0] to invoke; falls back to `/usr/bin/open` on any
    /// inconsistent state (unknown enum, empty `customCommand`).
    static func currentCommand(defaults: UserDefaults = .standard) -> String {
        let raw =
            defaults.string(forKey: AppearanceTab.Keys.editor)
            ?? EditorChoice.defaultOpen.rawValue
        guard let choice = EditorChoice(rawValue: raw) else { return "/usr/bin/open" }
        if choice == .other {
            let custom =
                defaults.string(forKey: AppearanceTab.Keys.customCommand) ?? ""
            return custom.isEmpty ? "/usr/bin/open" : custom
        }
        return choice.command ?? "/usr/bin/open"
    }
}
