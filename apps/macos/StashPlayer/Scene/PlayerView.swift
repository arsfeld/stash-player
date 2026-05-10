import SwiftUI
import AVKit
import AVFoundation
import AppKit

/// SwiftUI wrapper around `AVPlayerView` that adds mpv-style keyboard
/// shortcuts (Space/k = play-pause, ←/→ = ∓5s, j/l = ∓10s, ↑/↓ = ±60s,
/// m = mute, f = fullscreen, 9/0 = volume).
///
/// AVPlayerView already handles single-click play/pause, has its own
/// fullscreen button, and gives us PiP for free, so we just layer the
/// custom keys on top rather than rebuilding the chrome from scratch.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> KeyCapturingPlayerView {
        let view = KeyCapturingPlayerView()
        view.player = player
        // Keep controlsStyle pinned to `.floating` and let AVKit manage
        // its own auto-hide. Switching this from `.floating` to `.none`
        // mid-fade is what left a translucent pill on screen after the
        // controls disappeared — letting AVKit own the full animation
        // cycle avoids that.
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ nsView: KeyCapturingPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// AVPlayerView subclass that captures arrow keys / space / etc. before
/// the system view's own handling steals them, and lets the user drag
/// the window from anywhere on the video surface (matches IINA / mpv /
/// Quicktime behaviour).
final class KeyCapturingPlayerView: AVPlayerView {
    override var acceptsFirstResponder: Bool { true }

    /// Where the current mouse-down landed. We defer the decision
    /// "click vs window-drag" until either the user moves enough
    /// (drag) or releases (click — currently a no-op since we let
    /// AVPlayerView's chrome handle its own button clicks).
    private var mouseDownLocation: NSPoint?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            window.makeFirstResponder(self)
            // Required for NSEvent's local mouseMoved monitor (used by
            // SceneView for chrome auto-hide) to receive events while
            // the cursor sits over the player surface.
            window.acceptsMouseMovedEvents = true
        }
        installDoubleClickRecognizer()
    }

    private func installDoubleClickRecognizer() {
        // Gesture recognizers run ahead of the responder chain, so this
        // sees the second click of a double-click even when AVPlayerView
        // would otherwise consume mouseDown for play/pause toggle. Using
        // a recognizer here also stops AppKit from delivering the first
        // click as a single-click action (it correctly gets deferred
        // until the double-click interval expires).
        guard !(gestureRecognizers.contains(where: { $0 is NSClickGestureRecognizer })) else {
            return
        }
        let dbl = NSClickGestureRecognizer(
            target: self,
            action: #selector(handleDoubleClick(_:))
        )
        dbl.numberOfClicksRequired = 2
        addGestureRecognizer(dbl)
    }

    @objc private func handleDoubleClick(_ sender: NSClickGestureRecognizer) {
        window?.toggleFullScreen(nil)
    }

    override func keyDown(with event: NSEvent) {
        guard let player = self.player, handle(event: event, player: player) else {
            super.keyDown(with: event)
            return
        }
    }

    // MARK: - Window dragging

    override func mouseDown(with event: NSEvent) {
        // Remember where the click started; if the user keeps the button
        // down and moves past a small threshold we'll start a window drag.
        // If a chrome button (play/pause, scrubber, fullscreen) is hit,
        // AppKit dispatches mouseDown to that subview first and we never
        // get here — so this only fires for clicks on the bare video.
        // Double-clicks are handled by the NSClickGestureRecognizer
        // installed in viewDidMoveToWindow, which runs before this.
        mouseDownLocation = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation, let window else {
            super.mouseDragged(with: event)
            return
        }
        let cur = event.locationInWindow
        let dx = cur.x - start.x
        let dy = cur.y - start.y
        // 4pt threshold so a tiny shake during a click doesn't whisk the
        // window away. Once we hand off to performDrag, AppKit owns the
        // event stream until mouseUp.
        if dx * dx + dy * dy > 16 {
            mouseDownLocation = nil
            window.performDrag(with: event)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        super.mouseUp(with: event)
    }

    private func handle(event: NSEvent, player: AVPlayer) -> Bool {
        if let c = event.charactersIgnoringModifiers?.lowercased().first {
            switch c {
            case " ", "k": togglePlayPause(player); return true
            case "j": seek(player, by: -10); return true
            case "l": seek(player, by: 10); return true
            case "m": player.isMuted.toggle(); return true
            case "f": window?.toggleFullScreen(nil); return true
            case "9": player.volume = max(0, player.volume - 0.1); return true
            case "0": player.volume = min(1, player.volume + 0.1); return true
            default: break
            }
        }
        switch Int(event.keyCode) {
        case 123: seek(player, by: -5); return true   // left
        case 124: seek(player, by: 5); return true    // right
        case 125: seek(player, by: -60); return true  // down
        case 126: seek(player, by: 60); return true   // up
        default: return false
        }
    }

    private func togglePlayPause(_ player: AVPlayer) {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    private func seek(_ player: AVPlayer, by delta: Double) {
        let cur = player.currentTime().seconds
        guard cur.isFinite else { return }
        let target = max(0, cur + delta)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}
