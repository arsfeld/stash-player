import SwiftUI
import AppKit

/// SwiftUI shim that exposes the underlying `NSWindow` for the view it's
/// placed in. Used by `SceneView` to set `contentAspectRatio` and
/// `isMovableByWindowBackground` — neither of which has a SwiftUI
/// equivalent on macOS as of macOS 14.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view isn't in a window yet at make-time. Defer the lookup
        // to the next runloop tick so `view.window` resolves.
        DispatchQueue.main.async { [weak view] in
            self.onWindow(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            self.onWindow(nsView?.window)
        }
    }
}
