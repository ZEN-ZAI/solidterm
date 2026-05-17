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

    @State private var selection: String

    init(tabs: [SettingsTab]) {
        self.tabs = tabs
        // M7-0: default to Appearance (M5-2's Claude default lives in
        // the differentiatorTabs path). Falls back to the first
        // registered tab when an unusual tab list is injected.
        let initial = tabs.first(where: { $0.id == "appearance" })?.id
            ?? tabs.first?.id ?? ""
        _selection = State(initialValue: initial)
    }

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
