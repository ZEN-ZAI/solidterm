// Implements spec/swift-app-modules.md §Settings Window — tab descriptor.
//
// `SettingsView` consumes `[SettingsTab]` instead of hard-coding a
// `TabView` with literal labels. Future M5-X / M6 builders register
// their tabs by appending a descriptor (e.g. M5-4 Library 3-tab will
// add its own descriptor under M6 once Library exists). This avoids
// every settings-touching teammate having to edit `SettingsView.body`.
//
// M7-0: `SettingsTab.defaults` returns Appearance + Keybindings only
// for the baseline-parity ship. The full 6-tab surface lives in
// `differentiatorTabs` for Phase 3+ re-enable.

import SwiftUI

/// One tab registered in the Settings window. The view-builder is a
/// closure so each tab can hold its own state without `SettingsView`
/// needing to know about it. `@MainActor` because the closure may
/// instantiate MainActor-isolated views (e.g. `HookEditorView`).
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
    /// M7-0: visible tabs trimmed to Appearance + Keybindings for the
    /// baseline-parity ship. The full 6-tab surface (Appearance,
    /// Terminal, Claude, Agents, Keybindings, Advanced —
    /// spec/swift-app-modules.md:357) lives in `differentiatorTabs`
    /// below; re-enable by returning that array from `defaults`.
    /// `projectRoot` is forwarded so the dormant Claude
    /// (HookEditor) tab still resolves when re-enabled.
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

/// Placeholder for not-yet-implemented tabs. Centralized so the five
/// stubs land identically and a future M6 task can `grep` for it to
/// find unimplemented tabs.
struct StubTabView: View {
    let name: String
    let milestone: String

    var body: some View {
        VStack(spacing: Theme.Spacing.one) {
            Spacer()
            Text(name)
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Coming soon — \(milestone)")
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.three)
    }
}
