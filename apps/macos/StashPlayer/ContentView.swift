import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { app.sidebarSelection },
                set: { app.sidebarSelection = $0 ?? .library }
            )) {
                Label("Library", systemImage: "rectangle.grid.2x2")
                    .tag(SidebarItem.library)
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
            .listStyle(.sidebar)
            .navigationTitle("Stash Player")
            .frame(minWidth: 180)
        } detail: {
            switch app.sidebarSelection {
            case .library:
                NavigationStack {
                    LibraryView()
                        .navigationDestination(for: FfiScene.self) { scene in
                            SceneView(scene: scene)
                        }
                }
            case .settings:
                NavigationStack { SettingsView() }
            }
        }
    }
}

