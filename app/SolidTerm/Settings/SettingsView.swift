// Implements spec/swift-app-modules.md §Settings Window — SwiftUI body.
//
// Descriptor-driven `TabView` per team-lead-2 M5-2 follow-up: M5-4
// Library and any later settings work will register their own
// `SettingsTab` rather than editing this file. Each tab descriptor
// supplies its own view-builder closure.
//
// The TabView itself uses macOS's system-managed tab-content
// background — fighting it produces uncanny chrome. Each tab is
// responsible for painting its own `bg-elevated` (#16161e) surface
// per design-tokens.md §"Surface levels"; HookEditorView does this
// explicitly (pixel-verified by SettingsViewTests).

import SwiftUI

@MainActor
struct SettingsView: View {
    let tabs: [SettingsTab]

    /// S5: last-selected tab id, persisted across sessions so the
    /// user lands back on the pane they were last editing. Falls
    /// back to "appearance" on first launch (or after a wipe).
    @AppStorage("solidterm.settings.selectedTab")
    private var selection: String = "appearance"

    var body: some View {
        TabView(selection: $selection) {
            ForEach(tabs) { tab in
                tab.content()
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .tag(tab.id)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
