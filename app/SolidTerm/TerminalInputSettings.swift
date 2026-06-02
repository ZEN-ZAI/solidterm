// Persistence namespace for keyboard-input behaviour preferences.
// Follows the per-feature UserDefaults-key convention used elsewhere
// (Theme.OSC133.userDefaultsKey, ScrollbackSettings.userDefaultsKey,
// AppearanceTab.Keys) — there is no centralized SettingsStore yet.

import Foundation

enum TerminalInputSettings {
    /// When true, Option+printable key sends `ESC` + the unmodified base
    /// character (e.g. Option+b → `ESC b`) instead of letting macOS
    /// compose a special character (é, ∑, …). Enables readline / emacs /
    /// zsh Meta bindings (M-b, M-f, M-d, …).
    ///
    /// Default false: Option keeps composing accented characters, so the
    /// muscle memory for é, ∑, etc. is unchanged unless the user opts in.
    static let optionAsMetaKey = "solidterm.input.optionAsMeta"

    /// Live read of the preference (false when unset — matches the
    /// off-by-default Toggle in Settings ▸ Appearance ▸ Keyboard).
    static var optionAsMeta: Bool {
        UserDefaults.standard.bool(forKey: optionAsMetaKey)
    }
}
