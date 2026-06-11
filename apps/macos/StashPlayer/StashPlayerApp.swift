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
        // Vanilla window chrome so the Library gets the system Liquid Glass
        // toolbar (incl. the macOS 27 toolbar/content divider). The scene
        // page establishes its own immersive, edge-to-edge video chrome in
        // SceneView.applyWindowChrome and reverts it on the way out.
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }

            // File > Re-scan Library
            CommandGroup(before: .newItem) {
                Button("Re-scan Library…") {
                    app.scanTrigger += 1
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            // View > Refresh — HIG requires every toolbar command to also
            // be in the menu bar so users can find it when the toolbar is
            // hidden or customized.
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Tasks") {
                    app.tasksTrigger += 1
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Refresh") {
                    app.refreshTrigger += 1
                }
                .keyboardShortcut("r", modifiers: .command)
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
