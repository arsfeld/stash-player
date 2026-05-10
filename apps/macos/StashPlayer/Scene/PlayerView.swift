import SwiftUI
import AVKit
import AVFoundation
import AppKit

/// SwiftUI wrapper around `AVPlayerView` with the native chrome stripped
/// (`controlsStyle = .none`) — the custom `OSDOverlay` provides the only
/// playback UI.
///
/// Keyboard shortcuts (Space/k = play/pause, ←/→ = ∓5s, j/l = ∓10s,
/// ↑/↓ = ±60s, m = mute, f = fullscreen, 9/0 = volume, i = info popover)
/// are handled here so they keep working when the OSD is hidden. Click
/// handling is split: a double-click `NSClickGestureRecognizer` toggles
/// fullscreen, while single-click + drag flow through the responder chain
/// to `mouseDown` / `mouseDragged` so a small drag promotes to
/// `window.performDrag(_:)` for window-move-from-anywhere.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    /// Any user input → bump the OSD's auto-hide timer.
    var onActivity: () -> Void = {}
    /// Called when the user presses `i` — opens the info popover.
    var onToggleInfo: () -> Void = {}

    func makeNSView(context: Context) -> KeyCapturingPlayerView {
        let view = KeyCapturingPlayerView()
        view.player = player
        // We render our own OSD on top, so hide the native chrome entirely.
        view.controlsStyle = .none
        view.onActivity = onActivity
        view.onToggleInfo = onToggleInfo
        return view
    }

    func updateNSView(_ nsView: KeyCapturingPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        // SwiftUI rebuilds the closures on every render — refresh the
        // captured copies so the AppKit side calls into the latest state.
        nsView.onActivity = onActivity
        nsView.onToggleInfo = onToggleInfo
    }
}

/// `AVPlayerView` subclass that captures keyboard, click, and drag events.
/// Double-clicks go through an NSClickGestureRecognizer (which doesn't
/// hold up the responder chain for single clicks); single clicks fall
/// through to mouseDown/mouseDragged so the user can drag the window
/// from any non-button area of the video.
final class KeyCapturingPlayerView: AVPlayerView {
    var onActivity: () -> Void = {}
    var onToggleInfo: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }

    /// Where the current mouse-down landed. Cleared by mouseDragged when
    /// promoted to a window drag — that null state suppresses the click
    /// handler in mouseUp.
    private var mouseDownLocation: NSPoint?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            window.makeFirstResponder(self)
            // mouseMoved events flow to the local NSEvent monitor in
            // SceneView; AppKit only delivers them when the window opts in.
            window.acceptsMouseMovedEvents = true
        }
        installDoubleClickRecognizer()
    }

    /// We use a recognizer for double-click instead of `event.clickCount`
    /// in `mouseUp` because AVPlayerView's own super-mouseUp can swallow
    /// the second event in subtle ways (the user could double-click and
    /// nothing happened). The recognizer is only watching for two clicks
    /// in quick succession — it neither delays single clicks nor blocks
    /// `mouseDragged`, so window-drag still works.
    private func installDoubleClickRecognizer() {
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
        onActivity()
        window?.toggleFullScreen(nil)
    }

    /// AVPlayerView binds `←` / `→` to these NSResponder actions by
    /// default — they advance one frame and pause the player. We want
    /// arrow keys to do a time-skip and keep playing, so we shadow both
    /// selectors. AppKit walks the responder chain looking for the first
    /// view that implements the selector; our override wins.
    @objc func stepForward(_ sender: Any?) {
        guard let player = self.player else { return }
        onActivity()
        seek(player, by: 5)
    }

    @objc func stepBackward(_ sender: Any?) {
        guard let player = self.player else { return }
        onActivity()
        seek(player, by: -5)
    }

    override func keyDown(with event: NSEvent) {
        guard let player = self.player, handle(event: event, player: player) else {
            super.keyDown(with: event)
            return
        }
    }

    // MARK: - Click + drag

    override func mouseDown(with event: NSEvent) {
        // Remember where the click started; mouseDragged promotes to a
        // window drag past a small threshold. Clicks on OSD buttons are
        // dispatched to SwiftUI before reaching us, so this only fires
        // for the bare-video area.
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
        // window away. Once handed off, AppKit owns the event stream.
        if dx * dx + dy * dy > 16 {
            mouseDownLocation = nil
            window.performDrag(with: event)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let dragged = (mouseDownLocation == nil)
        mouseDownLocation = nil
        super.mouseUp(with: event)
        if !dragged {
            onActivity()
        }
    }

    private func handle(event: NSEvent, player: AVPlayer) -> Bool {
        if let c = event.charactersIgnoringModifiers?.lowercased().first {
            switch c {
            case " ", "k": onActivity(); togglePlayPause(player); return true
            case "j": onActivity(); seek(player, by: -10); return true
            case "l": onActivity(); seek(player, by: 10); return true
            case "m": onActivity(); player.isMuted.toggle(); return true
            case "f": onActivity(); window?.toggleFullScreen(nil); return true
            case "9": onActivity(); player.volume = max(0, player.volume - 0.1); return true
            case "0": onActivity(); player.volume = min(1, player.volume + 0.1); return true
            case "i": onActivity(); onToggleInfo(); return true
            default: break
            }
        }
        switch Int(event.keyCode) {
        case 123: onActivity(); seek(player, by: -5); return true   // left
        case 124: onActivity(); seek(player, by: 5); return true    // right
        case 125: onActivity(); seek(player, by: -60); return true  // down
        case 126: onActivity(); seek(player, by: 60); return true   // up
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

    /// Seek with a 1s tolerance window. `.zero` tolerance forces the
    /// decoder to land on an exact frame, which can stall the player for
    /// half a second on H.264/HEVC and trip the `timeControlStatus`
    /// observer into the "paused" state. 1s of slop is invisible to the
    /// user for skip-by-time and keeps the rate steady.
    private func seek(_ player: AVPlayer, by delta: Double) {
        let cur = player.currentTime().seconds
        guard cur.isFinite else { return }
        let target = max(0, cur + delta)
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }
}
