import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @State private var scenes: [FfiScene] = []
    @State private var query: String = ""
    @State private var page: UInt32 = 1
    @State private var totalCount: Int64 = 0
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var loadError: String?

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 280), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                    NavigationLink(value: scene) {
                        SceneCardView(scene: scene)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if hasMore && !isLoading && index >= scenes.count - 4 {
                            Task { await loadNextPage() }
                        }
                    }
                }
            }
            .padding(20)

            if isLoading {
                ProgressView().padding()
            }
            if let loadError {
                Text(loadError).foregroundStyle(.red).padding()
            }
            if !hasMore && !scenes.isEmpty {
                Text("\(scenes.count) of \(totalCount) scenes")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .navigationTitle("Library")
        .searchable(text: $query, placement: .toolbar, prompt: "Search scenes")
        .task { await reload() }
        .task(id: query) { await debouncedReload() }
    }

    private func debouncedReload() async {
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            await reload()
        } catch {
            // Cancelled by next keystroke; ignore.
        }
    }

    private func reload() async {
        guard case .connected = app.status else { return }
        page = 1
        scenes = []
        hasMore = true
        loadError = nil
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await app.listScenes(
                query: query.isEmpty ? nil : query,
                page: page
            )
            totalCount = result.count
            scenes.append(contentsOf: result.scenes)
            if result.scenes.isEmpty || Int64(scenes.count) >= result.count {
                hasMore = false
            } else {
                page += 1
            }
        } catch {
            loadError = error.localizedDescription
            hasMore = false
        }
    }
}
