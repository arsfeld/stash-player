import SwiftUI
import AVKit
import AVFoundation
import AppKit

/// How often to flush a partial activity update to Stash while playing.
/// Matches the GTK app's ~10s throttle.
private let activityFlushInterval: Double = 10

/// Idle delay before the chrome (toolbar + cursor) auto-hides during
/// active playback. 2.5s matches what Plex / Apple TV / IINA settle on —
/// long enough that brief hesitations don't strobe the chrome,
/// short enough that an idle viewer gets a clean frame quickly.
private let chromeIdleHideSeconds: Double = 2.5

struct SceneView: View {
    let initial: SceneNavigation
    @Binding var navigationPath: NavigationPath
    @EnvironmentObject var app: AppState

    @State private var scene: FfiScene
    @State private var index: Int
    @State private var total: Int64
    @State private var filter: LibraryFilter

    @State private var avPlayer: AVPlayer?
    @State private var loadError: String?
    @State private var isNavigating = false

    // Activity tracking. We accumulate watch time client-side so each
    // throttled flush sends a non-zero `playDuration` delta — Stash bumps
    // play_count whenever any positive duration arrives.
    @State private var lastPlayStart: Date?
    @State private var accumulatedDelta: Double = 0
    @State private var lastFlushAt: Date = .distantPast
    @State private var rateObserver: NSKeyValueObservation?
    @State private var periodicToken: Any?

    @State private var liveOCount: Int32?
    @State private var oError: String?
    @State private var nowPlaying = NowPlayingController()
    /// Cinema mode collapses the metadata panel so the player fills the
    /// whole window. On by default — the user opens the scene page to
    /// watch, not to read. Toggled via the toolbar button or the 'c' key.
    @AppStorage("scene.cinemaMode") private var cinemaMode: Bool = true

    /// Drives the auto-hiding chrome (window toolbar + cursor). Visible
    /// initially; an idle timer hides it during active playback, mouse
    /// movement reveals it. Standard mature-video-app behaviour (Plex,
    /// Apple TV, IINA).
    @State private var chromeVisible: Bool = true
    @State private var idleHideTask: Task<Void, Never>?
    /// NSEvent monitor for mouse movement. AVPlayerView swallows enough
    /// mouse traffic that SwiftUI's `.onContinuousHover` alone misses
    /// most movements over the player; an NSEvent monitor catches them
    /// at the window level so chrome auto-hide stays responsive.
    @State private var mouseMoveMonitor: Any?
    /// Notification observer for window fullscreen exit. While in
    /// fullscreen the chrome may auto-hide and our `applyToolbarVisibility`
    /// sets `window.toolbar = nil` — so on exit AppKit has nothing to
    /// restore and the toolbar never reappears. Wake the chrome on exit
    /// to recreate it.
    @State private var fullScreenExitObserver: NSObjectProtocol?
    /// Last absolute cursor location we treated as movement. AppKit
    /// fires zero-delta moveMoved events when the cursor "settles"
    /// after a fullscreen transition; comparing absolute positions is
    /// the only reliable way to filter them out.
    @State private var lastMouseLocation: NSPoint = .zero
    /// Cached window so we can clear contentAspectRatio on disappear
    /// even if the SwiftUI view tree has been torn down already.
    @State private var hostWindow: NSWindow?

    init(initial: SceneNavigation, navigationPath: Binding<NavigationPath>) {
        self.initial = initial
        self._navigationPath = navigationPath
        self._scene = State(initialValue: initial.scene)
        self._index = State(initialValue: initial.index)
        self._total = State(initialValue: initial.total)
        self._filter = State(initialValue: initial.filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            videoSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !cinemaMode {
                metadataPanel
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .background(WindowAccessor { window in
            self.hostWindow = window
            applyWindowChrome(window)
            applyToolbarVisibility(window)
        })
        .navigationTitle(scene.displayTitle)
        .toolbar { toolbarContent }
        // Hide the toolbar's own background so it doesn't leave a
        // translucent strip lingering once the items themselves hide.
        // The buttons stay perfectly readable against the dark video.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar(chromeVisible ? .visible : .hidden, for: .windowToolbar)
        .onChange(of: cinemaMode) { _, _ in applyWindowChrome(hostWindow) }
        .onChange(of: scene.id) { _, _ in applyWindowChrome(hostWindow) }
        .onChange(of: chromeVisible) { _, _ in applyToolbarVisibility(hostWindow) }
        .task(id: scene.id) { await reloadPlayer() }
        .onAppear(perform: installMouseMoveMonitor)
        .onDisappear(perform: handleDisappear)
        .onContinuousHover(coordinateSpace: .global) { phase in
            switch phase {
            case .active(let location):
                let dx = location.x - lastMouseLocation.x
                let dy = location.y - lastMouseLocation.y
                if abs(dx) + abs(dy) > 1.5 {
                    lastMouseLocation = location
                    wakeChrome()
                }
            case .ended:
                break
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.init("c")) {
            withAnimation(.easeInOut(duration: 0.18)) { cinemaMode.toggle() }
            return .handled
        }
    }

    @ViewBuilder
    private var metadataPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadata
                performerChips
                if let details = scene.details, !details.isEmpty {
                    Text(details)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                fileInfo
            }
            .padding(20)
        }
        // Cap so the panel doesn't eat more than ~40 % of a tall window —
        // the video should always feel like the main act.
        .frame(maxHeight: 360)
    }

    // MARK: - Video surface

    @ViewBuilder
    private var videoSurface: some View {
        ZStack(alignment: .topTrailing) {
            playerOrPlaceholder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            skipOverlay

            if let stars = ratingStars, chromeVisible {
                Text("★ \(stars, specifier: "%.1f")")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 56)
                    .padding(.trailing, 14)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.18), value: chromeVisible)
            }
        }
        // Solid hit shape so SwiftUI's hover detection sees the full
        // area, even where the AVPlayerView's chrome would otherwise
        // capture mouse events.
        .contentShape(Rectangle())
    }

    /// Translucent ⏪10 / ⏩10 buttons centred vertically over the video.
    /// `AVPlayerView`'s built-in fast-forward/rewind buttons change the
    /// playback rate; users almost always want to skip-by-time instead,
    /// so we surface explicit, obviously-labelled skip controls.
    @ViewBuilder
    private var skipOverlay: some View {
        if chromeVisible {
            HStack(spacing: 0) {
                skipButton(systemImage: "gobackward.10", label: "Back 10 seconds") {
                    skipPlayer(by: -10)
                }
                Spacer(minLength: 60)
                skipButton(systemImage: "goforward.10", label: "Forward 10 seconds") {
                    skipPlayer(by: 10)
                }
            }
            .padding(.horizontal, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.18), value: chromeVisible)
            // Don't intercept hover/clicks outside the buttons, so the
            // user can still drag the window from anywhere on the video.
            .allowsHitTesting(true)
        }
    }

    private func skipButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.black.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func skipPlayer(by delta: Double) {
        guard let player = avPlayer else { return }
        let cur = player.currentTime().seconds
        guard cur.isFinite else { return }
        let target = max(0, cur + delta)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        // Reaching for skip implies engagement → reset the idle timer.
        wakeChrome()
    }

    @ViewBuilder
    private var playerOrPlaceholder: some View {
        if isNavigating {
            ProgressView().controlSize(.large)
        } else if let avPlayer {
            PlayerView(player: avPlayer)
        } else if let loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(loadError).foregroundStyle(.secondary).padding()
            }
        } else {
            ProgressView()
        }
    }

    private var ratingStars: Double? {
        guard let r = scene.rating100, r > 0 else { return nil }
        return Double(r) / 20.0
    }

    // MARK: - Metadata + chips

    private var subtitleLine: String {
        var parts: [String] = []
        if let studio = scene.studio?.name { parts.append(studio) }
        if let date = scene.date { parts.append(date) }
        if let dur = scene.files.first?.duration { parts.append(formatDuration(dur)) }
        if let f = scene.files.first, let w = f.width, let h = f.height {
            parts.append("\(w)×\(h)")
        }
        return parts.joined(separator: " · ")
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(scene.displayTitle).font(.title)
                Spacer()
                oCounterControls
            }
            if !subtitleLine.isEmpty {
                Text(subtitleLine).foregroundStyle(.secondary)
            }
            if let played = scene.playCount, played > 0 {
                Text("Played \(played) time\(played == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var performerChips: some View {
        if !scene.performers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(scene.performers, id: \.id) { performer in
                        HStack(spacing: 6) {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundStyle(.secondary)
                            Text(performer.name).font(.callout)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }

    private var oCounterControls: some View {
        let displayed = liveOCount ?? scene.oCounter ?? 0
        return HStack(spacing: 8) {
            if displayed > 0 {
                Text("O \(displayed)")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.tertiary.opacity(0.6), in: Capsule())
            }
            Button {
                Task { await bumpO() }
            } label: {
                Label("O", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Increment O-counter")

            if displayed > 0 {
                Button(role: .destructive) {
                    Task { await zeroO() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset O-counter")
            }

            if let oError {
                Text(oError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var fileInfo: some View {
        if let f = scene.files.first {
            GroupBox("File") {
                VStack(alignment: .leading, spacing: 4) {
                    if let codec = f.videoCodec { labelRow("Codec", codec) }
                    if let w = f.width, let h = f.height {
                        labelRow("Resolution", "\(w)×\(h)")
                    }
                    if let fps = f.frameRate {
                        labelRow("Frame rate", String(format: "%.2f fps", fps))
                    }
                    if let dur = f.duration {
                        labelRow("Duration", formatDuration(dur))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func labelRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    // MARK: - Toolbar (prev/next)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await navigate(by: -1) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!canGoPrev)
            .help("Previous scene")

            Button {
                Task { await navigate(by: 1) }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!canGoNext)
            .help("Next scene")

            // Cinema toggle: an icon-only button is too easily missed in
            // a sea of chevrons, so we ship an icon + "Cinema" label.
            // YouTube's theater toggle uses the same pattern (icon +
            // tooltip + visible state). The filled vs. outline variant
            // signals the active state at a glance.
            Toggle(isOn: Binding(
                get: { cinemaMode },
                set: { newValue in
                    withAnimation(.easeInOut(duration: 0.18)) { cinemaMode = newValue }
                }
            )) {
                Label("Cinema", systemImage: cinemaMode
                      ? "rectangle.inset.filled"
                      : "rectangle")
            }
            .toggleStyle(.button)
            .help(cinemaMode
                  ? "Cinema mode is on — click or press C to show details"
                  : "Cinema mode — hide details for full-window playback (C)")

            Button {
                openInStash()
            } label: {
                Image(systemName: "safari")
            }
            .help("Open in Stash")
        }
    }

    private func openInStash() {
        guard case .connected = app.status else { return }
        // `try?` on a throws -> FfiCredentials? returns FfiCredentials??.
        // Flatten before unwrapping.
        let credsOpt = (try? app.player.loadSavedCredentials()) ?? nil
        guard let creds = credsOpt, let base = URL(string: creds.baseUrl) else { return }
        // Stash's web UI uses /scenes/<id>; baseUrl already includes the
        // scheme + host the user pointed at via Settings.
        let url = base.appendingPathComponent("scenes").appendingPathComponent(scene.id)
        NSWorkspace.shared.open(url)
    }

    private var canGoPrev: Bool { index > 0 && !isNavigating }
    private var canGoNext: Bool {
        !isNavigating && (total < 0 || Int64(index) + 1 < total)
    }

    // MARK: - Player loading + activity

    @MainActor
    private func reloadPlayer() async {
        tearDownPlayer(flush: false)
        liveOCount = nil
        loadError = nil

        // Refresh metadata so the page reflects play_count / o_counter
        // updates that landed via prev/next or another client.
        // `try?` on a throws -> FfiScene? gives us FfiScene?? — flatten before
        // unwrapping or the second `if let` won't compile.
        let refreshed = (try? await app.getScene(id: scene.id)) ?? nil
        if let refreshed { scene = refreshed }

        guard let stream = scene.paths.stream else {
            loadError = "Scene has no stream URL"
            return
        }
        do {
            let signed = try app.authenticatedUrl(stream)
            guard let url = URL(string: signed) else {
                loadError = "Bad stream URL"
                return
            }
            let player = AVPlayer(url: url)
            attachRateObserver(player)
            attachPeriodicObserver(player)
            avPlayer = player

            if let resume = scene.resumeTime, resume > 5 {
                let target = CMTime(seconds: resume, preferredTimescale: 600)
                await player.seek(
                    to: target,
                    toleranceBefore: .zero,
                    toleranceAfter: .positiveInfinity
                )
            }
            player.play()
            await bindNowPlaying(player: player)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func attachRateObserver(_ player: AVPlayer) {
        rateObserver = player.observe(\.rate, options: [.old, .new]) { _, change in
            let oldRate = change.oldValue ?? 0
            let newRate = change.newValue ?? 0
            Task { @MainActor in
                if newRate > 0 && oldRate == 0 {
                    lastPlayStart = Date()
                    // Resume → start the auto-hide countdown.
                    scheduleChromeHide()
                } else if newRate == 0 && oldRate > 0 {
                    if let start = lastPlayStart {
                        accumulatedDelta += Date().timeIntervalSince(start)
                        lastPlayStart = nil
                    }
                    // Pause → stay visible; user wants the controls.
                    pinChromeVisible()
                    Task { await flushActivity(player: player) }
                }
            }
        }
    }

    // MARK: - Chrome auto-hide

    /// Mouse moved or any other "user is here" signal. Show chrome (if
    /// hidden) and restart the idle countdown.
    @MainActor
    private func wakeChrome() {
        if !chromeVisible {
            withAnimation(.easeOut(duration: 0.18)) { chromeVisible = true }
        }
        scheduleChromeHide()
    }

    /// Cancel any pending hide and pin chrome visible (used while paused).
    @MainActor
    private func pinChromeVisible() {
        idleHideTask?.cancel()
        idleHideTask = nil
        if !chromeVisible {
            withAnimation(.easeOut(duration: 0.18)) { chromeVisible = true }
        }
    }

    @MainActor
    private func scheduleChromeHide() {
        idleHideTask?.cancel()
        idleHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(chromeIdleHideSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Only hide if the player is actively playing — paused means
            // the user is reaching for controls.
            guard let p = avPlayer, p.timeControlStatus == .playing else { return }
            withAnimation(.easeIn(duration: 0.35)) { chromeVisible = false }
            // Cursor disappears alongside the toolbar; AppKit auto-shows
            // it on the next mouse-moved event.
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func attachPeriodicObserver(_ player: AVPlayer) {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        periodicToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { _ in
            Task { @MainActor in
                nowPlaying.tick()
                let now = Date()
                let elapsed = now.timeIntervalSince(lastFlushAt)
                if elapsed >= activityFlushInterval && lastPlayStart != nil {
                    await flushActivity(player: player)
                }
            }
        }
    }

    @MainActor
    private func bindNowPlaying(player: AVPlayer) async {
        var thumb: NSImage? = nil
        if let url = scene.paths.screenshot ?? scene.paths.preview {
            thumb = try? await app.fetchThumbnail(url: url)
        }
        nowPlaying.bind(
            player: player,
            title: scene.displayTitle,
            subtitle: scene.studio?.name ?? "",
            durationSeconds: scene.files.first?.duration,
            thumbnail: thumb
        )
    }

    @MainActor
    private func flushActivity(player: AVPlayer) async {
        var play = accumulatedDelta
        if let start = lastPlayStart {
            let now = Date()
            play += now.timeIntervalSince(start)
            lastPlayStart = now
        }
        accumulatedDelta = 0
        lastFlushAt = Date()

        let resume = player.currentTime().seconds
        let resumeOpt: Double? = resume.isFinite ? resume : nil
        let durationOpt: Double? = play > 0 ? play : nil

        await app.saveActivity(
            id: scene.id,
            resumeTime: resumeOpt,
            playDuration: durationOpt
        )
    }

    private func tearDownPlayer(flush: Bool) {
        if let player = avPlayer, flush {
            // Synchronous final flush on disappear/swap. We snapshot the
            // player position here because tearing down the observers
            // will lose it otherwise.
            var play = accumulatedDelta
            if let start = lastPlayStart {
                play += Date().timeIntervalSince(start)
            }
            let resume = player.currentTime().seconds
            let id = scene.id
            let durationOpt: Double? = play > 0 ? play : nil
            let resumeOpt: Double? = resume.isFinite ? resume : nil
            Task { [app] in
                await app.saveActivity(
                    id: id,
                    resumeTime: resumeOpt,
                    playDuration: durationOpt
                )
            }
        }
        rateObserver?.invalidate()
        rateObserver = nil
        if let token = periodicToken {
            avPlayer?.removeTimeObserver(token)
            periodicToken = nil
        }
        avPlayer?.pause()
        avPlayer = nil
        nowPlaying.tearDown()
        accumulatedDelta = 0
        lastPlayStart = nil
        lastFlushAt = .distantPast
    }

    private func handleDisappear() {
        idleHideTask?.cancel()
        idleHideTask = nil
        if let m = mouseMoveMonitor {
            NSEvent.removeMonitor(m)
            mouseMoveMonitor = nil
        }
        if let obs = fullScreenExitObserver {
            NotificationCenter.default.removeObserver(obs)
            fullScreenExitObserver = nil
        }
        // Restore the cursor in case we were mid-hide when leaving the
        // scene page.
        NSCursor.unhide()
        // Drop the aspect-ratio constraint so the library window isn't
        // stuck snapping to the last scene's dimensions, and re-attach
        // a toolbar so the library page has its chrome back.
        if let window = hostWindow {
            window.contentAspectRatio = .zero
            if window.toolbar == nil {
                let tb = NSToolbar(identifier: "library-toolbar")
                tb.showsBaselineSeparator = false
                window.toolbar = tb
            }
            window.toolbar?.isVisible = true
        }
        tearDownPlayer(flush: true)
    }

    /// Toggle the toolbar's visibility to match `chromeVisible`.
    ///
    /// We deliberately do *not* set `window.toolbar = nil` to hide it,
    /// even though that fully removes the chrome strip: SwiftUI's
    /// `.toolbar { ... }` items don't re-attach to a hand-created bare
    /// NSToolbar, so toggling between nil and a new toolbar leaves the
    /// header empty when it comes back. `isVisible` preserves SwiftUI's
    /// items, and the transparent titlebar + `titlebarSeparatorStyle =
    /// .none` keep the hidden state from leaving a visible strip.
    @MainActor
    private func applyToolbarVisibility(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarSeparatorStyle = .none
        window.toolbar?.isVisible = chromeVisible
    }

    /// Apply the immersive window chrome — drag-from-anywhere, a
    /// transparent titlebar so the video flows under the traffic
    /// lights, and (in cinema mode) a contentAspectRatio that snaps
    /// the window to the video's native dimensions on resize.
    @MainActor
    private func applyWindowChrome(_ window: NSWindow?) {
        guard let window else { return }
        // Movable from any background area. KeyCapturingPlayerView also
        // forwards drags from over the player surface so the user can
        // grab the whole window from the video.
        window.isMovableByWindowBackground = true

        // Without these, the titlebar region paints a system material
        // that shows up as a strip at the top of the video even after
        // we hide the toolbar items + background. Transparent titlebar
        // + fullSizeContentView lets the black video extend behind the
        // (invisible) titlebar all the way to the window edge.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // macOS 12+ separator line under the titlebar — drawn even with
        // a transparent titlebar, so kill it explicitly.
        window.titlebarSeparatorStyle = .none
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }

        if cinemaMode,
           let f = scene.files.first,
           let w = f.width, let h = f.height,
           w > 0, h > 0 {
            window.contentAspectRatio = NSSize(width: Int(w), height: Int(h))
        } else {
            // .zero clears the constraint per AppKit docs.
            window.contentAspectRatio = .zero
        }
    }

    /// Force chrome (and therefore the window toolbar) back when leaving
    /// fullscreen. Without this the toolbar never reappears if the user
    /// exited fullscreen while the chrome was auto-hidden — at that point
    /// `window.toolbar` was nil and AppKit has nothing to restore.
    @MainActor
    private func installFullScreenExitObserver() {
        guard fullScreenExitObserver == nil else { return }
        fullScreenExitObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                pinChromeVisible()
                applyToolbarVisibility(hostWindow)
            }
        }
    }

    @MainActor
    private func installMouseMoveMonitor() {
        installFullScreenExitObserver()
        guard mouseMoveMonitor == nil else { return }
        lastMouseLocation = NSEvent.mouseLocation
        mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { event in
            // Compare absolute cursor positions instead of trusting
            // NSEvent.delta. The OS synthesizes mouseMoved events with
            // bogus delta values when transitioning to/from fullscreen
            // and when the cursor is "settling"; absolute position is
            // the ground truth.
            Task { @MainActor in
                let cur = NSEvent.mouseLocation
                let dx = cur.x - lastMouseLocation.x
                let dy = cur.y - lastMouseLocation.y
                if abs(dx) + abs(dy) > 1.5 {
                    lastMouseLocation = cur
                    wakeChrome()
                }
            }
            return event
        }
    }

    // MARK: - Prev / next

    @MainActor
    private func navigate(by delta: Int) async {
        let target = index + delta
        guard target >= 0, !isNavigating else { return }
        if total >= 0 && Int64(target) >= total { return }

        isNavigating = true
        defer { isNavigating = false }

        // Stop the current playback first so audio doesn't keep playing
        // while the spinner is up. Flushes the in-flight activity.
        tearDownPlayer(flush: true)

        do {
            // Stash pages are 1-indexed; per_page=1 reads the scene at
            // `target` from the same filter ordering the user is browsing.
            let result = try await app.listScenes(
                filter: filter,
                page: UInt32(target + 1),
                perPage: 1
            )
            guard let next = result.scenes.first else {
                loadError = "No scene at position \(target + 1)"
                return
            }
            scene = next
            index = target
            total = result.count
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - O-counter

    @MainActor
    private func bumpO() async {
        oError = nil
        do {
            let new = try await app.incrementO(id: scene.id)
            liveOCount = new
        } catch {
            oError = error.localizedDescription
        }
    }

    @MainActor
    private func zeroO() async {
        oError = nil
        do {
            let new = try await app.resetO(id: scene.id)
            liveOCount = new
        } catch {
            oError = error.localizedDescription
        }
    }
}
