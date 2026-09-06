// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// Q2 — UserDefaults namespace for the configurable scrollback knob
// plus the cross-cutting "Reset all settings" helper.

import Foundation

enum ScrollbackSettings {
    /// `Int`-typed; 0 means "use engine default (`DEFAULT_SCROLLBACK_LINES`)".
    static let userDefaultsKey = "solidterm.scrollback"

    /// Wipe every UserDefaults key the app owns. Domains we own:
    /// anything under the `solidterm.*` prefix (file-path click,
    /// scrollback, OSC 133 accent, settings selected tab) and the
    /// well-known FontSettings + KeybindingStore + ThemeManager
    /// owned keys. Anything we DON'T own — system-injected
    /// AppleLanguages, NSWindow frame autosave keys, etc. — is
    /// preserved.
    static func resetAll() {
        let defaults = UserDefaults.standard
        let domain =
            defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
            ?? [:]
        for key in domain.keys {
            if key.hasPrefix("solidterm.")
                || key.hasPrefix("FontSettings.")
                || key.hasPrefix("Keybinding")
                || key.hasPrefix("Theme")
            {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.synchronize()
    }
}
