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

/// Snapshot of the window-chrome properties `SceneView` mutates for its
/// immersive video look, so they can be restored to whatever the OS gave us
/// rather than to hardcoded "vanilla" guesses (the actual defaults differ
/// between macOS versions). Captured once, before the first immersive
/// mutation; reapplied verbatim when the scene page tears down.
struct WindowChromeSnapshot {
    let isMovableByWindowBackground: Bool
    let titlebarAppearsTransparent: Bool
    let titleVisibility: NSWindow.TitleVisibility
    let titlebarSeparatorStyle: NSTitlebarSeparatorStyle
    let hadFullSizeContentView: Bool
    let contentAspectRatio: NSSize

    @MainActor
    init(_ window: NSWindow) {
        isMovableByWindowBackground = window.isMovableByWindowBackground
        titlebarAppearsTransparent = window.titlebarAppearsTransparent
        titleVisibility = window.titleVisibility
        titlebarSeparatorStyle = window.titlebarSeparatorStyle
        hadFullSizeContentView = window.styleMask.contains(.fullSizeContentView)
        contentAspectRatio = window.contentAspectRatio
    }

    @MainActor
    func restore(to window: NSWindow) {
        window.isMovableByWindowBackground = isMovableByWindowBackground
        window.titlebarAppearsTransparent = titlebarAppearsTransparent
        window.titleVisibility = titleVisibility
        window.titlebarSeparatorStyle = titlebarSeparatorStyle
        if hadFullSizeContentView {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
        window.contentAspectRatio = contentAspectRatio
    }
}
