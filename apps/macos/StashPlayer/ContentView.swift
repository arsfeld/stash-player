import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var libraryPath = NavigationPath()
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationStack(path: $libraryPath) {
            mainContent
                .navigationDestination(for: SceneNavigation.self) { nav in
                    SceneView(initial: nav, navigationPath: $libraryPath)
                }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch app.status {
        case .connected:
            LibraryView(navigationPath: $libraryPath)
        case .connecting:
            ProgressView("Connecting to Stash…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .disconnected, .failed:
            unconnectedPlaceholder
        }
    }

    private var unconnectedPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Not connected to Stash")
                .font(.title2)
            if case .failed(let m) = app.status {
                Text(m)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else {
                Text("Open Settings to enter your Stash URL and API key.")
                    .foregroundStyle(.secondary)
            }
            Button("Open Settings…") { openSettings() }
                .controlSize(.large)
                .keyboardShortcut(",", modifiers: [.command])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
