import Sparkle
import SwiftUI

@main
struct StashPlayerMacApp: App {
    @StateObject private var app = AppState()

    // Sparkle 2.x requires `SPUStandardUpdaterController` to be a plain
    // stored property (not `@StateObject` — it isn't `ObservableObject`).
    // `startingUpdater: true` schedules the first background check on launch
    // and the periodic 24 h cadence; both honor the `SUEnableAutomaticChecks`
    // Info.plist default and the user's later toggle in Settings.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

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
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        // Standard macOS Settings scene. SwiftUI wires Cmd-, to it
        // automatically and renders a proper Preferences-style window.
        Settings {
            SettingsView(updater: updaterController.updater)
                .environmentObject(app)
                .frame(minWidth: 460, minHeight: 240)
        }
    }
}
