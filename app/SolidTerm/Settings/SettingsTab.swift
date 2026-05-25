// Settings window tab descriptor.
//
// `SettingsView` consumes `[SettingsTab]` instead of hard-coding a
// `TabView` with literal labels. New tab surfaces register by
// appending a descriptor — keeps `SettingsView.body` ignorant of
// each tab's content.

import SwiftUI

/// One tab registered in the Settings window. The view-builder is a
/// closure so each tab can hold its own state without `SettingsView`
/// needing to know about it.
@MainActor
struct SettingsTab: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let content: @MainActor () -> AnyView

    init<Content: View>(
        id: String,
        title: String,
        systemImage: String,
        @ViewBuilder content: @escaping @MainActor () -> Content
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.content = { AnyView(content()) }
    }
}

extension SettingsTab {
    /// SolidTerm ships two tabs: Appearance (theme / font / shell
    /// integration / file-path click) and Keybindings (M6-5 customizer).
    /// `projectRoot` is reserved for future per-project surfaces.
    static func defaults(projectRoot _: URL) -> [SettingsTab] {
        [
            SettingsTab(id: "appearance", title: "Appearance", systemImage: "paintbrush") {
                AppearanceTab()
            },
            SettingsTab(id: "keybindings", title: "Keybindings", systemImage: "keyboard") {
                KeybindingsTab()
            },
        ]
    }
}
