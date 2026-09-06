// App lifecycle and `@main`.
// SwiftUI's `@main` only satisfies the entry-point requirement; AppDelegate
// owns NSWindow creation and all real lifecycle.
//
// The `Settings { EmptyView() }` scene is the only valid `Scene` we
// declare (App needs at least one), but its auto-installed "Settings…"
// command (the `.appSettings` CommandGroup) opens an empty SwiftUI-
// managed window that competes with `SettingsWindowController` — same
// chrome title "SolidTerm Settings" (CFBundleName + " Settings"), empty
// body — which produces the "blank settings" regression seen after
// dcfd139. That commit fixed the contentViewController binding path
// on OUR window, but missed this second scene-level path where
// SwiftUI's own window was opening instead. `CommandGroup(replacing:
// .appSettings)` strips SwiftUI's Cmd-, handler so `AppMenu`'s
// manually-registered Preferences item (action `openSettingsWindow`,
// binding `.openSettings`) is the sole route to Settings.

import SwiftUI

@main
struct SolidTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) { EmptyView() }
            }
    }
}
