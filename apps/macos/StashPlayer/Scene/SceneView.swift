import SwiftUI
import AVKit
import AVFoundation
import AppKit
import os.log

private let logger = Logger(subsystem: "dev.arsfeld.stash-player", category: "SceneView")

/// How often to flush a partial activity update to Stash while playing.
/// Matches the GTK app's ~10s throttle.
private let activityFlushInterval: Double = 10

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
    @State private var statusObserver: NSKeyValueObservation?
    @State private var periodicToken: Any?

    /// Power-management assertion held while the player is actively playing
    /// so the display doesn't dim or sleep mid-scene. AVPlayer's implicit
    /// `preventsDisplaySleepDuringVideoPlayback` is unreliable through this
    /// custom `controlsStyle = .none` render path, so we hold an explicit
    /// `ProcessInfo` activity instead. Begun on the rate 0→playing edge,
    /// ended on pause and teardown.
    @State private var sleepAssertion: NSObjectProtocol?

    @State private var liveOCount: Int32?
    @State private var oError: String?
    @State private var nowPlaying = NowPlayingController()

    /// Custom Infuse-style OSD: one cohesive top + bottom panel pair that
    /// replaces AVKit's native controls + the old toolbar + the old skip
    /// circles + the old metadata panel. The view-model owns auto-hide,
    /// scrubber state, volume bindings, and play/pause state.
    @StateObject private var osdVM = OSDViewModel()

    /// Persisted across sessions so the user's preference survives app
    /// relaunches. Default ON so a fresh install autoplays through the
    /// library — the user can opt out via the OSD toggle. The on-end
    /// notification observer reads this to decide whether to auto-advance.
    @AppStorage("scene.autoplay") private var autoplay: Bool = true

    /// Drives the `InfoPopover` visibility. Toggled by the ⓘ button in
    /// the OSD as well as the `i` keyboard shortcut, which is why it lives
    /// here rather than inside `OSDOverlay`.
    @State private var showInfo: Bool = false

    /// NSEvent monitor for mouse movement. AVPlayerView swallows enough
    /// mouse traffic that SwiftUI's `.onContinuousHover` alone misses
    /// most movements over the player; the window-level monitor catches
    /// them so OSD auto-hide stays responsive.
    @State private var mouseMoveMonitor: Any?
    /// Window-level keyDown monitor for arrow keys. AVPlayerView binds
    /// ←/→/↑/↓ to its built-in frame-step actions; even with our
    /// `stepForward:` / `stepBackward:` overrides, focus drift to a
    /// SwiftUI subview lets the originals fire. Intercepting at the
    /// monitor layer guarantees arrow keys always do a time skip and
    /// never frame-step + pause.
    @State private var keyDownMonitor: Any?
    /// Last absolute cursor location we treated as movement. AppKit fires
    /// zero-delta moveMoved events when the cursor "settles" after a
    /// fullscreen transition; comparing absolute positions is the only
    /// reliable way to filter them out.
    @State private var lastMouseLocation: NSPoint = .zero
    /// Cached window so we can clear contentAspectRatio on disappear even
    /// if the SwiftUI view tree has been torn down already.
    @State private var hostWindow: NSWindow?
    /// Notification observer for end-of-playback → autoplay next.
    @State private var endObserver: NSObjectProtocol?
    /// The shared window's chrome as it was before we applied the immersive
    /// look, captured once on first appear and restored verbatim on
    /// disappear so the Library gets back exactly the OS default — not a
    /// hardcoded approximation of it.
    @State private var savedChrome: WindowChromeSnapshot?

    init(initial: SceneNavigation, navigationPath: Binding<NavigationPath>) {
        self.initial = initial
        self._navigationPath = navigationPath
        self._scene = State(initialValue: initial.scene)
        self._index = State(initialValue: initial.index)
        self._total = State(initialValue: initial.total)
        self._filter = State(initialValue: initial.filter)
    }

    var body: some View {
        videoSurface
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Extend the video + OSD under the titlebar so the bare video
            // shows behind the (transparent) traffic-light strip instead
            // of a safe-area-inset black bar.
            .ignoresSafeArea()
            .background(Color.black.ignoresSafeArea())
            .background(WindowAccessor { window in
                self.hostWindow = window
                applyWindowChrome(window)
            })
            // No toolbar and no navigationTitle on the scene page: the
            // window is a normal titled window whose traffic lights float
            // over the video via the transparent, full-size-content-view
            // titlebar set in `applyWindowChrome`. The OSD top bar carries
            // the scene title and our own auto-fading back chevron, so a
            // SwiftUI toolbar here would only add a redundant inline title
            // and a macOS 27 section divider over the video.
            .navigationBarBackButtonHidden(true)
            .onChange(of: scene.id) { _, _ in applyWindowChrome(hostWindow) }
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
                        osdVM.bumpReveal()
                    }
                case .ended:
                    // Cursor left the window — hide the OSD right away
                    // instead of waiting out the 2.5s timer. Matches
                    // Infuse: the OSD follows the cursor.
                    osdVM.hideImmediately()
                }
            }
            // Deliberately no `.focusable()` — that would compete with
            // `KeyCapturingPlayerView` for first-responder status and let
            // arrow keys fall through to AVPlayerView's built-in
            // stepForward/stepBackward, which step one frame and pause.
    }

    // MARK: - Video surface + OSD

    @ViewBuilder
    private var videoSurface: some View {
        ZStack {
            playerOrPlaceholder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            if avPlayer != nil {
                OSDOverlay(
                    vm: osdVM,
                    scene: scene,
                    oCount: liveOCount ?? scene.oCounter ?? 0,
                    canGoPrev: canGoPrev,
                    canGoNext: canGoNext,
                    autoplay: $autoplay,
                    showInfo: $showInfo,
                    onClose: { dismissScene() },
                    onPrev: { Task { await navigate(by: -1) } },
                    onNext: { Task { await navigate(by: 1) } },
                    onToggleFullscreen: { hostWindow?.toggleFullScreen(nil) },
                    onBumpO: { Task { await bumpO() } },
                    onResetO: { Task { await zeroO() } },
                    onOpenInStash: { openInStash() }
                )
            }
        }
        // Note: deliberately no `.contentShape(Rectangle())` — that would
        // make the ZStack itself a click target and break the bare-video
        // pass-through that `KeyCapturingPlayerView.mouseDown` uses to
        // start a window drag.
    }

    @ViewBuilder
    private var playerOrPlaceholder: some View {
        if isNavigating {
            ProgressView().controlSize(.large)
        } else if let avPlayer {
            PlayerView(
                player: avPlayer,
                onActivity: { osdVM.bumpReveal() },
                onToggleInfo: {
                    osdVM.bumpReveal()
                    showInfo.toggle()
                }
            )
        } else if let loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(loadError).foregroundStyle(.secondary).padding()
            }
        } else {
            ProgressView()
        }
    }

    private func dismissScene() {
        if !navigationPath.isEmpty {
            navigationPath.removeLast()
        }
    }

    private func openInStash() {
        guard case .connected = app.status else { return }
        // `try?` on a throws -> FfiCredentials? returns FfiCredentials??.
        // Flatten before unwrapping.
        let credsOpt = (try? app.player.loadSavedCredentials()) ?? nil
        guard let creds = credsOpt, let base = URL(string: creds.baseUrl) else { return }
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
            logger.info("Loading stream: \(url.absoluteString.replacing(/apikey=[^&]+/, with: "apikey=***"), privacy: .public)")
            let player = AVPlayer(url: url)
            // Restore the previously chosen volume/mute before the OSD
            // attaches and reads `player.volume`/`player.isMuted`. AVPlayer
            // defaults to 1.0 / false on a fresh instance, so without this
            // every scene swap would silently reset the user's preference.
            // `object(forKey:)` lets us distinguish "never set" from "set
            // to 0" — `double(forKey:)` would treat both as 0 and mute.
            let savedVolume = (UserDefaults.standard.object(
                forKey: OSDViewModel.volumeDefaultsKey
            ) as? Double) ?? 1.0
            player.volume = Float(max(0, min(1, savedVolume)))
            player.isMuted = UserDefaults.standard.bool(forKey: OSDViewModel.mutedDefaultsKey)
            // Document intent at the source: the explicit ProcessInfo
            // assertion (beginSleepAssertion) is the real safeguard, but
            // keep the implicit flag on too so AVPlayer cooperates.
            player.preventsDisplaySleepDuringVideoPlayback = true
            attachRateObserver(player)
            attachPeriodicObserver(player)
            attachEndObserver(player)
            attachStatusObserver(player)
            avPlayer = player
            // Seed the OSD's known duration from FFI metadata so the
            // scrubber range isn't 0…1 for the first ~150ms while the
            // AVAsset finishes loading.
            osdVM.attach(to: player)
            if let dur = scene.files.first?.duration {
                osdVM.seedDuration(dur)
            }

            if let resume = effectiveResumeSeconds(for: scene) {
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
                nowPlaying.tick()
                if newRate > 0 && oldRate == 0 {
                    lastPlayStart = Date()
                    beginSleepAssertion()
                } else if newRate == 0 && oldRate > 0 {
                    endSleepAssertion()
                    if let start = lastPlayStart {
                        accumulatedDelta += Date().timeIntervalSince(start)
                        lastPlayStart = nil
                    }
                    Task { await flushActivity(player: player) }
                }
            }
        }
    }

    private func attachPeriodicObserver(_ player: AVPlayer) {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        periodicToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { time in
            Task { @MainActor in
                nowPlaying.tick()
                osdVM.tick(
                    currentTime: time,
                    duration: player.currentItem?.duration
                )
                let now = Date()
                let elapsed = now.timeIntervalSince(lastFlushAt)
                if elapsed >= activityFlushInterval && lastPlayStart != nil {
                    await flushActivity(player: player)
                }
            }
        }
    }

    /// Resume position the player should actually seek to, or `nil` to
    /// start from the beginning. Mirrors `Scene::effective_resume_secs`
    /// in `stash-api`: Stash keeps the saved `resume_time` near the
    /// duration when the user watches a scene to completion, and seeking
    /// there on re-open immediately fires end-of-stream — which the
    /// autoplay end observer then turns into a confusing auto-advance
    /// to the next scene. Treat resumes within the last 10s — or past
    /// 97% of the known duration — as "finished, play from the start".
    private func effectiveResumeSeconds(for scene: FfiScene) -> Double? {
        guard let resume = scene.resumeTime, resume > 5 else { return nil }
        if let duration = scene.files.first?.duration,
           duration > 0,
           resume >= duration - 10 || resume / duration >= 0.97 {
            return nil
        }
        return resume
    }

    /// Auto-advance to the next scene in the current filter when playback
    /// reaches the end and the autoplay toggle is on. Mirrors the GTK
    /// app's "play next" behaviour at end-of-stream.
    private func attachEndObserver(_ player: AVPlayer) {
        guard let item = player.currentItem else { return }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard autoplay, canGoNext else { return }
                await navigate(by: 1)
            }
        }
    }

    /// Watch for AVPlayerItem load failures. Without this observer,
    /// playback errors (network, codec, auth) are silently swallowed and
    /// the user sees a blank player forever.
    private func attachStatusObserver(_ player: AVPlayer) {
        guard let item = player.currentItem else { return }
        statusObserver = item.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed else { return }
            let msg = item.error?.localizedDescription ?? "Unknown playback error"
            logger.error("AVPlayerItem failed: \(msg, privacy: .public)")
            Task { @MainActor in
                avPlayer = nil
                loadError = msg
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
            sceneID: scene.id,
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

    /// Hold a display-awake assertion while playing. Idempotent — a second
    /// play→play edge won't stack a duplicate. `.userInitiated` also tells
    /// the system this is active foreground work so App Nap doesn't throttle
    /// the playback observers (the "as if it's idle" symptom).
    private func beginSleepAssertion() {
        guard sleepAssertion == nil else { return }
        sleepAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: "Playing video"
        )
    }

    private func endSleepAssertion() {
        guard let token = sleepAssertion else { return }
        ProcessInfo.processInfo.endActivity(token)
        sleepAssertion = nil
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
        statusObserver?.invalidate()
        statusObserver = nil
        if let token = periodicToken {
            avPlayer?.removeTimeObserver(token)
            periodicToken = nil
        }
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        osdVM.detach()
        endSleepAssertion()
        avPlayer?.pause()
        avPlayer = nil
        nowPlaying.tearDown()
        accumulatedDelta = 0
        lastPlayStart = nil
        lastFlushAt = .distantPast
    }

    private func handleDisappear() {
        if let m = mouseMoveMonitor {
            NSEvent.removeMonitor(m)
            mouseMoveMonitor = nil
        }
        if let k = keyDownMonitor {
            NSEvent.removeMonitor(k)
            keyDownMonitor = nil
        }
        // Hand the shared window back to exactly the chrome it had before
        // this scene page touched it, so the Library keeps the OS-default
        // (vanilla) toolbar behaviour for whatever macOS version we're on.
        if let window = hostWindow, let snapshot = savedChrome {
            snapshot.restore(to: window)
        }
        savedChrome = nil
        tearDownPlayer(flush: true)
    }

    /// Apply the immersive window chrome — drag-from-anywhere, transparent
    /// titlebar so the video flows under the traffic lights, no NSToolbar
    /// at all (the OSD's top bar replaces it), and a contentAspectRatio
    /// that snaps the window to the video's native dimensions on resize.
    @MainActor
    private func applyWindowChrome(_ window: NSWindow?) {
        guard let window else { return }
        // Capture the OS-default chrome before the first mutation so we can
        // hand it back untouched on disappear (applyWindowChrome also runs
        // on scene.id changes — only the first call snapshots).
        if savedChrome == nil {
            savedChrome = WindowChromeSnapshot(window)
        }
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // macOS 12+ separator line under the titlebar — drawn even with
        // a transparent titlebar, so kill it explicitly.
        window.titlebarSeparatorStyle = .none
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if !window.styleMask.contains(.titled) {
            window.styleMask.insert(.titled)
        }

        // Defensive: anything that flipped `isHidden` upstream (e.g. a
        // fullscreen exit) would leave the standard window buttons off.
        // Force them on every time we apply chrome.
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false

        if let f = scene.files.first,
           let w = f.width, let h = f.height,
           w > 0, h > 0 {
            window.contentAspectRatio = NSSize(width: Int(w), height: Int(h))
        } else {
            window.contentAspectRatio = .zero
        }
    }

    @MainActor
    private func installMouseMoveMonitor() {
        installKeyDownMonitor()
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
                // Skip if the cursor has already left the window.
                // Without this guard a tail mouseMoved (dispatched
                // async to MainActor) lands after onContinuousHover's
                // .ended branch hid the OSD, reviving it for ~2.5s.
                if let win = hostWindow, !win.frame.contains(cur) {
                    return
                }
                let dx = cur.x - lastMouseLocation.x
                let dy = cur.y - lastMouseLocation.y
                if abs(dx) + abs(dy) > 1.5 {
                    lastMouseLocation = cur
                    osdVM.bumpReveal()
                }
            }
            return event
        }
    }

    @MainActor
    private func installKeyDownMonitor() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Skip when a modifier is held — Cmd+arrow etc. should still
            // reach the menu, and so should anything the user is typing
            // into a system-provided field (shouldn't happen on this
            // page, but cheap defence).
            let mods = event.modifierFlags
                .intersection([.command, .option, .control])
            guard mods.isEmpty else { return event }

            switch Int(event.keyCode) {
            case 123: // ←
                Task { @MainActor in osdVM.bumpReveal(); osdVM.skip(by: -5) }
                return nil
            case 124: // →
                Task { @MainActor in osdVM.bumpReveal(); osdVM.skip(by: 5) }
                return nil
            case 125: // ↓
                Task { @MainActor in osdVM.bumpReveal(); osdVM.skip(by: -60) }
                return nil
            case 126: // ↑
                Task { @MainActor in osdVM.bumpReveal(); osdVM.skip(by: 60) }
                return nil
            default:
                return event
            }
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

