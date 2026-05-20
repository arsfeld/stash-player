import Foundation
import AVFoundation
import Combine

/// Owns the player-driven state and auto-hide lifecycle for the custom
/// Infuse-style OSD. SceneView feeds it the player + periodic time ticks;
/// the OSD overlay reads `@Published` state and calls back via
/// `togglePlayPause`, `skip`, `setVolume`, etc.
///
/// Auto-hide rules mirror the GTK app:
///   - 2.5s of inactivity → fade out (only while playing).
///   - Any user signal (mouse move, key press, scrubber drag, button tap)
///     → `bumpReveal()` to fade in + restart the timer.
///   - Paused → `pinVisible()` to cancel the timer; the user is reaching
///     for controls.
@MainActor
final class OSDViewModel: ObservableObject {
    /// Drives the fade. Starts visible so the first frame on a new scene
    /// shows the OSD; the existing reveal/hide rules take over once the
    /// player begins playing.
    @Published var revealed: Bool = true
    @Published var currentSeconds: Double = 0
    @Published var durationSeconds: Double = 0
    @Published var isPlaying: Bool = false
    @Published var volume: Float = 0.7
    @Published var isMuted: Bool = false
    /// Set while the user is dragging the scrubber. The scrubber binds to
    /// this value for live preview while suppressing the periodic observer
    /// from snapping the thumb back to the player's stale position. Mirrors
    /// the GTK player's `Rc<Cell<bool>>` feedback-loop guard.
    @Published var seekDraftSeconds: Double?

    /// 2.5s matches GTK's `HIDE_DELAY_MS` and the muscle-memory of Plex /
    /// Apple TV / IINA.
    let hideDelay: Double = 2.5

    /// UserDefaults keys used to persist volume + mute across videos and
    /// app restarts. Read by `SceneView.reloadPlayer()` to seed each fresh
    /// `AVPlayer`; written below from the volume/mute KVO observers so
    /// every change path (slider, keyboard, mute toggle) lands in storage.
    static let volumeDefaultsKey = "scene.volume"
    static let mutedDefaultsKey = "scene.muted"

    private weak var player: AVPlayer?
    private var rateObs: NSKeyValueObservation?
    private var volObs: NSKeyValueObservation?
    private var mutedObs: NSKeyValueObservation?
    private var hideTask: Task<Void, Never>?

    func attach(to player: AVPlayer) {
        detach()
        self.player = player
        self.volume = player.volume
        self.isMuted = player.isMuted
        self.isPlaying = (player.timeControlStatus != .paused)
        // Reset duration so a previously-loaded scene's value doesn't leak
        // into the freshly-attached player while the new asset loads.
        self.durationSeconds = 0
        self.currentSeconds = 0

        // Treat `.waitingToPlayAtSpecifiedRate` as "still playing" — that
        // state fires during seek stalls and brief buffer underruns. If
        // we flip `isPlaying` false on it the play/pause icon blinks and
        // the OSD pins itself visible during routine playback hiccups.
        // Only explicit `.paused` (user pressed pause) counts as paused.
        rateObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = (p.timeControlStatus != .paused)
            Task { @MainActor in
                self?.isPlaying = playing
                if playing {
                    self?.scheduleHide()
                } else {
                    self?.pinVisible()
                }
            }
        }
        volObs = player.observe(\.volume, options: [.new]) { [weak self] _, change in
            let v = change.newValue ?? 0
            Task { @MainActor in
                self?.volume = v
                UserDefaults.standard.set(Double(v), forKey: Self.volumeDefaultsKey)
            }
        }
        mutedObs = player.observe(\.isMuted, options: [.new]) { [weak self] _, change in
            let m = change.newValue ?? false
            Task { @MainActor in
                self?.isMuted = m
                UserDefaults.standard.set(m, forKey: Self.mutedDefaultsKey)
            }
        }
    }

    func detach() {
        rateObs?.invalidate(); rateObs = nil
        volObs?.invalidate(); volObs = nil
        mutedObs?.invalidate(); mutedObs = nil
        hideTask?.cancel(); hideTask = nil
        player = nil
        seekDraftSeconds = nil
    }

    /// Called from the SceneView periodic time observer (4 Hz). Skipping
    /// `currentSeconds` while a scrub is in flight keeps the thumb from
    /// fighting the user's drag.
    func tick(currentTime: CMTime, duration: CMTime?) {
        let cur = currentTime.seconds
        if cur.isFinite, seekDraftSeconds == nil {
            currentSeconds = cur
        }
        if let d = duration?.seconds, d.isFinite, d > 0 {
            durationSeconds = d
        }
    }

    /// Used by SceneView to seed duration from FFI metadata before the
    /// AVAsset loads its own — otherwise the scrubber range is 0 for the
    /// first ~150ms of playback.
    func seedDuration(_ seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        if durationSeconds <= 0 {
            durationSeconds = seconds
        }
    }

    func bumpReveal() {
        if !revealed { revealed = true }
        scheduleHide()
    }

    func pinVisible() {
        hideTask?.cancel()
        hideTask = nil
        if !revealed { revealed = true }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.hideDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Hide unless the user explicitly paused. Buffering / waiting
            // counts as "still playing" so a hiccup doesn't pin the OSD.
            guard self.player?.timeControlStatus != .paused else { return }
            self.revealed = false
        }
    }

    // MARK: - Scrubber

    func beginSeekDraft(_ value: Double) {
        seekDraftSeconds = clampSeek(value)
    }

    func updateSeekDraft(_ value: Double) {
        seekDraftSeconds = clampSeek(value)
    }

    func commitSeekDraft() {
        defer { seekDraftSeconds = nil }
        guard let target = seekDraftSeconds, let player else { return }
        currentSeconds = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func clampSeek(_ value: Double) -> Double {
        guard durationSeconds > 0 else { return max(0, value) }
        return min(max(0, value), durationSeconds)
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    /// Seek with 1s tolerance — `.zero` tolerance forces an exact-frame
    /// decode that can stall H.264/HEVC playback for ~0.5s and trip the
    /// `timeControlStatus` observer into a transient pause state. 1s of
    /// slop is invisible for skip-by-time and keeps the rate steady so
    /// the OSD play/pause icon doesn't blink during a skip.
    func skip(by delta: Double) {
        guard let player else { return }
        let cur = player.currentTime().seconds
        guard cur.isFinite else { return }
        var target = max(0, cur + delta)
        if durationSeconds > 0 {
            target = min(target, durationSeconds)
        }
        currentSeconds = target
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    // MARK: - Volume

    func setVolume(_ v: Float) {
        let clamped = min(max(0, v), 1)
        player?.volume = clamped
        volume = clamped
    }

    func toggleMute() {
        guard let player else { return }
        player.isMuted.toggle()
    }
}
