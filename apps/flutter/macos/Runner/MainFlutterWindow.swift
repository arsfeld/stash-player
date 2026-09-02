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
    // An empty toolbar in the unified style is what makes AppKit treat the
    // titlebar as a taller band and re-centre the traffic lights inside it.
    // Without it the lights sit in a 28pt titlebar, which leaves the app's
    // own strip no room for padding above its controls without falling off
    // the lights' centre line. Nothing is ever added to this toolbar; the
    // Flutter view draws every control.
    // `toolbarStyle` arrived in macOS 11 and the deployment target is
    // still 10.15. On 10.15 the window keeps its 28pt titlebar, so the
    // lights sit above the app's own controls rather than on their centre
    // line, since AppTokens.macOSStripHeight describes where macOS 11+
    // draws them. Accepted: the strip stays usable and nothing overlaps.
    if #available(macOS 11.0, *) {
      let toolbar = NSToolbar(identifier: "stash-player-titlebar-spacer")
      self.toolbar = toolbar
      self.toolbarStyle = .unified
    }
    // Once the Flutter view covers the titlebar it also swallows the drag
    // events, so without this the window cannot be moved by its top
    // strip. The cost is that a drag starting anywhere on a
    // non-interactive background also moves the window.
    self.isMovableByWindowBackground = true
    // Below this, the app's own top strip and the player bar are not even
    // the first things to break -- AppWindowChrome is a bare Row with no
    // overflow protection of its own, and the library toolbar goes first.
    self.minSize = NSSize(width: 480, height: 400)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
