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
    /// Persisted toolbar choice. The Toggle writes to this and to
    /// `filter.hideInteractive` together so `.task(id: filter)` reloads
    /// the grid in lockstep with the saved value.
    @AppStorage("library.hideInteractive") private var persistedHideInteractive: Bool = false
    /// Tasks popover state.
    @State private var activeJobs: [FfiJob] = []
    @State private var showTasksPopover = false
    @State private var isScanning = false
    @State private var jobTrackingTask: Task<Void, Never>?

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
                // Seed the persisted toolbar value into the filter BEFORE the
                // initial reload so we don't fetch a non-interactive-excluded
                // page only to immediately discard it.
                filter.hideInteractive = persistedHideInteractive
                didFirstLoad = true
                await reload()
            }
        }
        .task(id: pendingQuery) { await debouncedSearch() }
        .task(id: filter) {
            // Skip the initial run; bootstrap covers it.
            if didFirstLoad { await reload() }
        }
        .onChange(of: app.refreshTrigger) {
            Task { await reload() }
        }
        .onChange(of: app.scanTrigger) {
            Task { await startScan() }
        }
        .onChange(of: app.tasksTrigger) {
            showTasksPopover = true
        }
        .onChange(of: showTasksPopover) { _, isOpen in
            if isOpen {
                Task { await refreshTasks() }
            } else {
                stopJobTrackingIfIdle()
            }
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

    /// True while a scan is in flight or Stash reports running/ready jobs.
    private var hasActiveWork: Bool {
        isScanning
            || activeJobs.contains { $0.status == .running || $0.status == .ready }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            leadingToolbarCluster
        }

        // Flexible space — without this, `.primaryAction` sits next to the
        // leading cluster instead of the trailing edge (especially with
        // `.searchable(placement: .toolbar)`).
        ToolbarItem {
            Spacer()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            trailingToolbarCluster
        }
    }

    /// Left: refresh → shuffle → inline filters.
    private var leadingToolbarCluster: some View {
        HStack(spacing: 8) {
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh scene list")

            Button {
                Task { await playRandom() }
            } label: {
                Image(systemName: "shuffle")
            }
            .help("Play a random scene matching the current filter")

            sortToolbarGroup
            ratingToolbarGroup
            visibilityFiltersToolbarGroup
        }
    }

    /// Right: a re-scan + tasks group. (Refresh lives in the leading
    /// cluster, before shuffle.)
    private var trailingToolbarCluster: some View {
        ControlGroup {
            Button {
                Task { await startScan() }
            } label: {
                Image(systemName: "externaldrive.badge.plus")
            }
            .help("Re-scan library for new media")
            .disabled(hasActiveWork)

            tasksToolbarButton
        }
    }

    private var sortToolbarGroup: some View {
        ControlGroup {
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
        }
    }

    private var ratingToolbarGroup: some View {
        ControlGroup {
            Picker("Min rating", selection: minRatingBinding) {
                ForEach(0..<minRatingOptions.count, id: \.self) { i in
                    Text(minRatingOptions[i].label).tag(i)
                }
            }
            .pickerStyle(.menu)
            .help("Minimum rating")
        }
    }

    private var visibilityFiltersToolbarGroup: some View {
        ControlGroup {
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

            Toggle(isOn: hideInteractiveBinding) {
                Image(systemName: "waveform.slash")
            }
            .toggleStyle(.button)
            .help(filter.hideInteractive
                  ? "Hiding interactive scenes — click to show all"
                  : "Showing all scenes — click to hide interactive")
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

    /// Two-way binding that keeps the Toggle, the active filter, and the
    /// persisted @AppStorage value in lockstep. Writing through the filter
    /// triggers `.task(id: filter)`, which reloads the grid.
    private var hideInteractiveBinding: Binding<Bool> {
        Binding(
            get: { filter.hideInteractive },
            set: { on in
                filter.hideInteractive = on
                persistedHideInteractive = on
            }
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

    // MARK: - Tasks popover

    private var tasksToolbarButton: some View {
        Button {
            showTasksPopover = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: hasActiveWork
                      ? "arrow.triangle.2.circlepath"
                      : "list.bullet.rectangle")
                if hasActiveWork {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                        .offset(x: 5, y: -5)
                }
            }
        }
        .help(hasActiveWork
              ? "Background tasks running — click for details"
              : "Background tasks")
        .popover(isPresented: $showTasksPopover, arrowEdge: .bottom) {
            tasksPopoverContent
        }
    }

    @ViewBuilder
    private var tasksPopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tasks")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Divider()

            if activeJobs.isEmpty {
                Text("No active tasks")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                List(activeJobs, id: \.id) { job in
                    HStack(spacing: 8) {
                        jobIcon(for: job.status)
                            .frame(width: 16, height: 16)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.description)
                                .font(.callout)
                                .lineLimit(2)
                            if let progress = job.progress, progress > 0 {
                                ProgressView(value: progress, total: 1.0)
                                    .progressViewStyle(.linear)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
                .frame(minHeight: 0, idealHeight: 120)
            }
        }
        .frame(width: 300)
    }

    @ViewBuilder
    private func jobIcon(for status: FfiJobStatus) -> some View {
        switch status {
        case .running, .ready:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 16, height: 16)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed, .cancelled:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func startScan() async {
        isScanning = true
        // Synthetic entry until the first poll lands — visible if Tasks is open.
        activeJobs = [FfiJob(
            id: "__scan__",
            status: .running,
            progress: nil,
            description: "Starting scan…"
        )]
        ensureJobTracking()
        do {
            _ = try await app.metadataScan()
        } catch {
            activeJobs = [FfiJob(
                id: "error",
                status: .failed,
                progress: nil,
                description: "Scan failed: \(error.localizedDescription)"
            )]
            isScanning = false
            stopJobTrackingIfIdle()
        }
        // Job tracking clears `isScanning` when server jobs finish.
    }

    /// One-shot fetch when the Tasks popover opens.
    private func refreshTasks() async {
        do {
            activeJobs = try await app.jobs()
        } catch {
            activeJobs = []
        }
        ensureJobTracking()
    }

    private func ensureJobTracking() {
        guard jobTrackingTask == nil else { return }
        jobTrackingTask = Task {
            defer { jobTrackingTask = nil }
            var didComplete = false
            var sawActiveJobs = false
            var hasActive = false
            // Bounds the "waiting for the server to register the scan job"
            // window so an instant scan (nothing to find) still concludes.
            var emptyScanPolls = 0
            // Keep polling while the popover is open, a local scan is in
            // flight, OR the server still reports active jobs. That last
            // clause is what keeps the toolbar badge honest after the
            // popover closes — without it, polling stops on close and the
            // badge freezes on its last snapshot (a stale "scanning" icon).
            while !Task.isCancelled && (showTasksPopover || isScanning || hasActive) {
                do {
                    let jobs = try await app.jobs()
                    let anyActive = jobs.contains { $0.status == .running || $0.status == .ready }
                    hasActive = anyActive

                    if anyActive {
                        sawActiveJobs = true
                        emptyScanPolls = 0
                        activeJobs = jobs
                    } else if isScanning && !sawActiveJobs && emptyScanPolls < 3 {
                        // Scan requested but the server hasn't registered the
                        // job yet — hold the "Starting scan…" marker and wait.
                        emptyScanPolls += 1
                    } else if sawActiveJobs || isScanning {
                        // We watched work run (or a scan we can't keep waiting
                        // on) and the queue has settled — it finished.
                        activeJobs = [FfiJob(
                            id: "__scan__",
                            status: .finished,
                            progress: 1,
                            description: "Scan complete"
                        )]
                        didComplete = true
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        if !showTasksPopover { activeJobs = [] }
                        break
                    } else {
                        // Opened with nothing running and no scan in flight.
                        activeJobs = showTasksPopover ? jobs : []
                        break
                    }
                } catch {
                    if !showTasksPopover { activeJobs = [] }
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            // Clear the scan flag *before* the final reload so the badge drops
            // the moment tracking ends, even if the reload takes a beat.
            isScanning = false
            if didComplete {
                await reload()
            }
        }
    }

    private func stopJobTrackingIfIdle() {
        // Don't tear down the poller while work is still in flight — let it
        // keep the toolbar badge live and self-terminate once jobs finish.
        guard !isScanning && !hasActiveWork else { return }
        jobTrackingTask?.cancel()
        jobTrackingTask = nil
    }
}
