import SwiftUI

@main
struct StashPlayerMacApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 900, minHeight: 600)
                .task { await app.bootstrap() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
