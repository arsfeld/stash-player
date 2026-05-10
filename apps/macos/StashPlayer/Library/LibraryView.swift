import SwiftUI

/// Stash's rating100 increments per "star". Index 0 is the "any rating"
/// sentinel — the dropdown swaps that for `nil` when building the filter.
private let minRatingOptions: [(label: String, value: Int32?)] = [
    ("Any rating", nil),
    ("1+ stars", 20),
    ("2+ stars", 40),
    ("3+ stars", 60),
    ("4+ stars", 80),
    ("5 stars", 100),
]

private let sortLabels: [(key: FfiSortKey, label: String)] = [
    (.date, "Date"),
    (.title, "Title"),
    (.rating, "Rating"),
    (.playCount, "Play count"),
    (.duration, "Duration"),
    (.createdAt, "Date added"),
    (.updatedAt, "Last updated"),
    (.random, "Random"),
]

/// Carries the active filter into `SceneView` so prev/next can fetch
/// neighbours in the same order the user is browsing.
struct SceneNavigation: Hashable {
    let scene: FfiScene
    let filter: LibraryFilter
    let index: Int
    let total: Int64
}

struct LibraryView: View {
    @EnvironmentObject var app: AppState
    @Binding var navigationPath: NavigationPath

    @State private var scenes: [FfiScene] = []
    @State private var filter = LibraryFilter()
    @State private var pendingQuery: String = ""
    @State private var page: UInt32 = 1
    @State private var totalCount: Int64 = 0
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var loadError: String?
    @State private var didFirstLoad = false

    private let columns = [
        GridItem(.adaptive(minimum: 240, maximum: 280), spacing: 16, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                    NavigationLink(value: SceneNavigation(
                        scene: scene,
                        filter: filter,
                        index: index,
                        total: totalCount
                    )) {
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

            footer
        }
        .navigationTitle("Library")
        .searchable(text: $pendingQuery, placement: .toolbar, prompt: "Search scenes")
        .toolbar { toolbarContent }
        .task {
            if !didFirstLoad {
                didFirstLoad = true
                await reload()
            }
        }
        .task(id: pendingQuery) { await debouncedSearch() }
        .task(id: filter) {
            // Skip the initial run; bootstrap covers it.
            if didFirstLoad { await reload() }
        }
    }

    @ViewBuilder
    private var footer: some View {
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
        if !isLoading && scenes.isEmpty && loadError == nil && didFirstLoad {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                Text("No scenes match the current filter").foregroundStyle(.secondary)
            }
            .padding(40)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Sort", selection: $filter.sort) {
                ForEach(sortLabels, id: \.key) { item in
                    Text(item.label).tag(item.key)
                }
            }
            .pickerStyle(.menu)
            .help("Sort order")

            Button {
                filter.direction = (filter.direction == .asc) ? .desc : .asc
            } label: {
                Image(systemName: filter.direction == .asc ? "arrow.up" : "arrow.down")
            }
            .help(filter.direction == .asc
                  ? "Ascending — click for descending"
                  : "Descending — click for ascending")

            Picker("Min rating", selection: minRatingBinding) {
                ForEach(0..<minRatingOptions.count, id: \.self) { i in
                    Text(minRatingOptions[i].label).tag(i)
                }
            }
            .pickerStyle(.menu)
            .help("Minimum rating")

            Toggle(isOn: organizedBinding) {
                Image(systemName: "checkmark.seal")
            }
            .toggleStyle(.button)
            .help(filter.organized == true
                  ? "Showing organized only — click to clear"
                  : "Filter to organized only")

            Toggle(isOn: $filter.hideTracked) {
                Image(systemName: "eye.slash")
            }
            .toggleStyle(.button)
            .help(filter.hideTracked
                  ? "Hiding scenes with O > 0 — click to show all"
                  : "Showing all scenes — click to hide tracked")

            Button {
                Task { await playRandom() }
            } label: {
                Image(systemName: "shuffle")
            }
            .help("Play a random scene matching the current filter")
        }
    }

    private var minRatingBinding: Binding<Int> {
        Binding(
            get: {
                minRatingOptions.firstIndex { $0.value == filter.minRating } ?? 0
            },
            set: { idx in
                filter.minRating = minRatingOptions[idx].value
            }
        )
    }

    /// Tri-state collapsed to a checkbox: off = no filter, on = organized
    /// only. The Linux app's switch behaves the same; "unorganized only"
    /// is rare enough we don't expose it on macOS.
    private var organizedBinding: Binding<Bool> {
        Binding(
            get: { filter.organized == true },
            set: { on in filter.organized = on ? true : nil }
        )
    }

    private func debouncedSearch() async {
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            if pendingQuery != filter.query {
                filter.query = pendingQuery
            }
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
        // Reseed shuffle each time the result set is reloaded so a fresh
        // random order is shown — and so order stays stable across paging
        // + scene-page neighbour lookups that follow.
        filter.randomSeed = (filter.sort == .random)
            ? UInt32.random(in: 1...UInt32.max)
            : nil
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await app.listScenes(filter: filter, page: page)
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

    private func playRandom() async {
        guard case .connected = app.status else { return }
        var randomFilter = filter
        randomFilter.sort = .random
        randomFilter.randomSeed = UInt32.random(in: 1...UInt32.max)
        do {
            let result = try await app.listScenes(
                filter: randomFilter,
                page: 1,
                perPage: 1
            )
            guard let scene = result.scenes.first else {
                loadError = "No scenes match the current filter"
                return
            }
            navigationPath.append(SceneNavigation(
                scene: scene,
                filter: randomFilter,
                index: 0,
                total: result.count
            ))
        } catch {
            loadError = error.localizedDescription
        }
    }
}
