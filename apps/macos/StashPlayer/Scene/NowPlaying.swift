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
    private var registeredHandlers: [Any] = []

    func bind(
        player: AVPlayer,
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
        if let thumbnail {
            let size = thumbnail.size
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: size) { _ in
                thumbnail
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing

        installHandlers()
    }

    /// Push a fresh elapsed-time snapshot so the lock-screen / menu-bar
    /// widget tracks playback. Cheap to call from the existing periodic
    /// observer; we only update the two volatile fields.
    func tick() {
        guard let player else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        let elapsed = player.currentTime().seconds
        if elapsed.isFinite {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState =
            (player.timeControlStatus == .playing) ? .playing : .paused
    }

    func tearDown() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
        cc.skipForwardCommand.removeTarget(nil)
        cc.skipBackwardCommand.removeTarget(nil)
        cc.changePlaybackPositionCommand.removeTarget(nil)
        registeredHandlers.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        player = nil
    }

    private func installHandlers() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.removeTarget(nil)
        cc.pauseCommand.removeTarget(nil)
        cc.togglePlayPauseCommand.removeTarget(nil)
        cc.skipForwardCommand.removeTarget(nil)
        cc.skipBackwardCommand.removeTarget(nil)
        cc.changePlaybackPositionCommand.removeTarget(nil)

        cc.skipForwardCommand.preferredIntervals = [10]
        cc.skipBackwardCommand.preferredIntervals = [10]

        cc.playCommand.addTarget { [weak self] _ in
            guard let self, let p = self.player else { return .commandFailed }
            p.play()
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let self, let p = self.player else { return .commandFailed }
            p.pause()
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, let p = self.player else { return .commandFailed }
            if p.timeControlStatus == .playing { p.pause() } else { p.play() }
            return .success
        }
        cc.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(by: 10) ?? .commandFailed
        }
        cc.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(by: -10) ?? .commandFailed
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let p = self.player,
                  let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            p.seek(
                to: CMTime(seconds: e.positionTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            return .success
        }
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
}
