import Foundation
import AVFoundation
import MediaPlayer
import AppKit

/// Wraps `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` for an
/// `AVPlayer`. The system uses this to render media keys, the menu-bar
/// "Now Playing" widget, AirPods stem controls, and the Touch Bar
/// transport on supported Macs. The activation is per-player: when the
/// scene goes away we tear it down so a stale "Now Playing" entry
/// doesn't outlive the visible UI.
@MainActor
final class NowPlayingController {
    private weak var player: AVPlayer?
    private var thumbnail: NSImage?
    private var title: String = ""
    private var subtitle: String = ""
    private var registeredHandlers: [(MPRemoteCommand, Any)] = []
    private var currentInfo: [String: Any] = [:]

    func bind(
        player: AVPlayer,
        sceneID: String,
        title: String,
        subtitle: String,
        durationSeconds: Double?,
        thumbnail: NSImage?
    ) {
        self.player = player
        self.title = title
        self.subtitle = subtitle
        self.thumbnail = thumbnail

        var info: [String: Any] = [
            "StashPlayerSceneID": sceneID,
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate,
        ]
        if let dur = durationSeconds, dur.isFinite {
            info[MPMediaItemPropertyPlaybackDuration] = dur
        }
        let elapsed = player.currentTime().seconds
        if elapsed.isFinite {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        if let thumbnail, thumbnail.size.width > 0, thumbnail.size.height > 0 {
            let size = thumbnail.size
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: size) { _ in
                thumbnail
            }
        }
        self.currentInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing

        installHandlers()
    }

    /// Push a fresh elapsed-time snapshot so the lock-screen / menu-bar
    /// widget tracks playback. Cheap to call from the existing periodic
    /// observer; we only update the two volatile fields.
    func tick() {
        guard let player else { return }
        currentInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        let elapsed = player.currentTime().seconds
        if elapsed.isFinite {
            currentInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
        MPNowPlayingInfoCenter.default().playbackState =
            (player.timeControlStatus == .playing) ? .playing : .paused
    }

    func tearDown() {
        clearRegisteredHandlers()

        // Only clear the now playing info if we are the active controller.
        // This prevents incoming views' info from being cleared by an outgoing view's teardown.
        if let currentID = currentInfo["StashPlayerSceneID"] as? String,
           let nowPlayingID = MPNowPlayingInfoCenter.default().nowPlayingInfo?["StashPlayerSceneID"] as? String,
           currentID == nowPlayingID {
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }

        self.currentInfo = [:]
        player = nil
    }

    private func installHandlers() {
        let cc = MPRemoteCommandCenter.shared()
        clearRegisteredHandlers()

        cc.skipForwardCommand.preferredIntervals = [10]
        cc.skipBackwardCommand.preferredIntervals = [10]

        let playTarget = cc.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            DispatchQueue.main.async {
                self.player?.play()
            }
            return .success
        }
        registeredHandlers.append((cc.playCommand, playTarget))

        let pauseTarget = cc.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            DispatchQueue.main.async {
                self.player?.pause()
            }
            return .success
        }
        registeredHandlers.append((cc.pauseCommand, pauseTarget))

        let toggleTarget = cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            DispatchQueue.main.async {
                guard let p = self.player else { return }
                if p.timeControlStatus == .playing { p.pause() } else { p.play() }
            }
            return .success
        }
        registeredHandlers.append((cc.togglePlayPauseCommand, toggleTarget))

        let skipForwardTarget = cc.skipForwardCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            DispatchQueue.main.async {
                _ = self.skip(by: interval)
            }
            return .success
        }
        registeredHandlers.append((cc.skipForwardCommand, skipForwardTarget))

        let skipBackwardTarget = cc.skipBackwardCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            DispatchQueue.main.async {
                _ = self.skip(by: -interval)
            }
            return .success
        }
        registeredHandlers.append((cc.skipBackwardCommand, skipBackwardTarget))

        let seekTarget = cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let time = e.positionTime
            DispatchQueue.main.async {
                self.player?.seek(
                    to: CMTime(seconds: time, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
            return .success
        }
        registeredHandlers.append((cc.changePlaybackPositionCommand, seekTarget))
    }

    private func clearRegisteredHandlers() {
        for (command, target) in registeredHandlers {
            command.removeTarget(target)
        }
        registeredHandlers.removeAll()
    }

    private func skip(by delta: Double) -> MPRemoteCommandHandlerStatus {
        guard let p = player else { return .commandFailed }
        let cur = p.currentTime().seconds
        guard cur.isFinite else { return .commandFailed }
        let target = max(0, cur + delta)
        p.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        return .success
    }

    deinit {
        let handlers = registeredHandlers
        DispatchQueue.main.async {
            for (command, target) in handlers {
                command.removeTarget(target)
            }
        }
    }
}
