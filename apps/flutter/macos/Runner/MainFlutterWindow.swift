import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Draw Flutter content under a transparent titlebar so the app's own
    // top strip *is* the titlebar, matching the released clients. The
    // strip reserves a leading inset for the traffic lights on this
    // platform (see AppWindowChrome).
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    // Once the Flutter view covers the titlebar it also swallows the drag
    // events, so without this the window cannot be moved by its top
    // strip. The cost is that a drag starting anywhere on a
    // non-interactive background also moves the window.
    self.isMovableByWindowBackground = true

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
