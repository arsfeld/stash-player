import SwiftUI

@main
struct StashPlayerMacApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 640, minHeight: 360)
                .task { await app.bootstrap() }
        }
        // Hide the title bar so the scene page can let the video flow
        // edge-to-edge under a compact, translucent toolbar.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Standard macOS Settings scene. SwiftUI wires Cmd-, to it
        // automatically and renders a proper Preferences-style window.
        Settings {
            SettingsView()
                .environmentObject(app)
                .frame(minWidth: 460, minHeight: 240)
        }
    }
}
