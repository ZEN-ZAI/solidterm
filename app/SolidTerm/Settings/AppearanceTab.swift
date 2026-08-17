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
    /// Q2 scrollback knob — 0 means "use engine default". Range
    /// 1_000…1_000_000 enforced by the stepper; the engine rejects
    /// anything above MAX_SCROLLBACK_LINES at session construction.
    @AppStorage(ScrollbackSettings.userDefaultsKey) private var scrollbackLines: Int = 0
    /// Option-as-Meta: send ESC+<key> for readline/emacs/zsh Meta
    /// bindings instead of composing accented characters. Default off so
    /// é/∑/… composition is unchanged unless the user opts in.
    @AppStorage(TerminalInputSettings.optionAsMetaKey) private var optionAsMeta: Bool = false
    /// Reopen windows/tabs on relaunch via NSWindowRestoration. Default
    /// on (unset reads as ON, matching RestoreSettings.enabled).
    @AppStorage(RestoreSettings.enabledKey) private var restoreWindows: Bool = true
    /// Type the previously-running command back onto the restored prompt
    /// (without executing it). Default on, matching
    /// RestoreSettings.prefillCommandEnabled.
    @AppStorage(RestoreSettings.prefillCommandKey) private var prefillCommand: Bool = true

    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var fontSettings = FontSettings.shared
    @ObservedObject private var themeFiles = ThemeFileStore.shared

    var body: some View {
        Form {
            themeSection
            fontSection
            commandMarkersSection
            filePathSection
            scrollbackSection
            keyboardSection
            restorationSection
            resetSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 420)
    }

    // MARK: Keyboard

    private var keyboardSection: some View {
        Section {
            Toggle("Use Option as Meta key", isOn: $optionAsMeta)
        } header: {
            Text("Keyboard")
        } footer: {
            Text(
                "When on, Option+key sends an ESC-prefixed sequence "
                    + "(e.g. Option+B → ESC B) for readline, emacs, and zsh "
                    + "Meta bindings. When off, Option composes accented "
                    + "characters normally (é, ∑, …).")
        }
    }

    // MARK: Window restoration

    private var restorationSection: some View {
        Section {
            Toggle("Reopen windows and tabs on relaunch", isOn: $restoreWindows)
            Toggle("Restore the last command at the prompt", isOn: $prefillCommand)
                .disabled(!restoreWindows)
        } header: {
            Text("Window restoration")
        } footer: {
            Text(
                "When on, SolidTerm reopens your previous windows and tabs "
                    + "on launch, each shell starting in its last working "
                    + "directory. Directories are also journalled every few "
                    + "seconds, so they survive a force quit or a crash. "
                    + "Scrollback is not restored.\n\n"
                    + "With the second option on, the command each window was "
                    + "running is typed back onto the prompt but NOT run — "
                    + "press Return to start it, or just keep typing to "
                    + "discard it.")
        }
    }

    // MARK: Q2 — Scrollback

    private var scrollbackSection: some View {
        Section {
            HStack {
                Stepper(
                    value: $scrollbackLines,
                    in: 0...1_000_000,
                    step: 1_000
                ) {
                    LabeledContent("Lines") {
                        Text(
                            scrollbackLines == 0
                                ? "Default (100,000)"
                                : "\(scrollbackLines.formatted())")
                            .monospacedDigit()
                    }
                }
            }
        } header: {
            Text("Scrollback")
        } footer: {
            Text(
                "Number of history lines kept per session. Takes effect on the next window or tab. 0 = engine default.")
        }
    }

    // MARK: Q2 — Reset

    @State private var showResetConfirm: Bool = false

    private var resetSection: some View {
        Section {
            HStack {
                Spacer()
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Text("Reset All Settings…")
                }
                .confirmationDialog(
                    "Reset all SolidTerm settings to defaults?",
                    isPresented: $showResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        ScrollbackSettings.resetAll()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "Theme, font, keybindings, and all other preferences will be restored to defaults. Open windows are unaffected; the next window pickup the cleared values.")
                }
            }
        }
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
        Section {
            Picker(
                "Family",
                selection: Binding(
                    get: { fontSettings.family },
                    set: { fontSettings.setFamily($0) }
                )
            ) {
                ForEach(availableFonts, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            Stepper(
                value: Binding(
                    get: { fontSettings.size },
                    set: { fontSettings.setSize($0) }
                ),
                in: FontSettings.minSize...FontSettings.maxSize,
                step: 1
            ) {
                LabeledContent("Size") {
                    Text("\(Int(fontSettings.size)) pt")
                        .monospacedDigit()
                }
            }
            Toggle(
                "Enable ligatures",
                isOn: Binding(
                    get: { fontSettings.ligatures },
                    set: { fontSettings.setLigatures($0) }
                ))
            // S2 font preview — renders the configured family/size/
            // ligatures so the user can sanity-check before closing
            // the panel. Stays inside Section so Form chrome groups
            // it with the rest of the font controls.
            fontPreviewRow
        } header: {
            Text("Font")
        } footer: {
            Text("Use ⌘+ / ⌘− to adjust size on the fly. ⌘0 resets to the default.")
        }
    }

    /// S2: live font preview. Uses an NSViewRepresentable wrapper so we
    /// can apply CoreText kCTFontFeatureTypeIdentifierKey for ligature
    /// toggling — SwiftUI's `.font` doesn't expose the CT feature dict.
    private var fontPreviewRow: some View {
        LabeledContent("Preview") {
            FontPreviewView(
                family: fontSettings.family,
                size: fontSettings.size,
                ligatures: fontSettings.ligatures)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
    }

    // MARK: M6-4a — Theme section

    private var themeSection: some View {
        Section {
            Picker(
                "Theme file",
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
            Picker(
                "Built-in mode",
                selection: Binding(
                    get: { themeManager.mode },
                    set: { themeManager.setMode($0) }
                )
            ) {
                ForEach(Theme.Mode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .disabled(themeFiles.current != nil)
            // S3 swatches — render the active theme's 16 ANSI colors +
            // bg/fg/cursor as a compact preview strip so the user
            // sees the palette without applying it first.
            themeSwatchesRow
        } header: {
            Text("Theme")
        } footer: {
            Text(
                "Themes live in ~/.config/solidterm/themes/*.toml — edit any file and the change applies live.")
        }
    }

    /// S3: ANSI palette + bg/fg/cursor swatches for the active theme.
    /// Reads from the same resolution path the renderer uses so what
    /// the user sees here matches what lands on screen.
    private var themeSwatchesRow: some View {
        LabeledContent("Preview") {
            ThemeSwatchesView(
                file: themeFiles.current,
                mode: themeManager.mode)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: M7-4 — Command markers section

    private var commandMarkersSection: some View {
        Section {
            Toggle("Show command markers", isOn: $osc133AccentEnabled)
        } header: {
            Text("Command markers")
        } footer: {
            Text(
                "Slim left-margin accent at each shell prompt, color-coded by exit status (running / success / error). Requires shell integration (OSC 133).")
        }
    }

    // MARK: M6-2 — File-path click section

    private var filePathSection: some View {
        Section {
            Toggle("Detect file paths under the cursor", isOn: $detectionEnabled)
            Picker("Open files in", selection: $editorRaw) {
                ForEach(EditorChoice.fixedChoices, id: \.rawValue) { choice in
                    Text(choice.label).tag(choice.rawValue)
                }
                Text("Other…").tag(EditorChoice.other.rawValue)
            }
            .disabled(!detectionEnabled)
            if EditorChoice(rawValue: editorRaw) == .other {
                LabeledContent("Command") {
                    TextField(
                        "/usr/local/bin/mate",
                        text: $customCommand
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(!detectionEnabled)
                }
            }
        } header: {
            Text("File-path click")
        } footer: {
            Text(
                "Hold ⌘ and click a file path in the terminal to open it. Detection is filesystem-confirmed — paths only highlight when the file exists.")
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
