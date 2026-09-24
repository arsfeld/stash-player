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
    let toolbar = NSToolbar(identifier: "stash-player-titlebar-spacer")
    self.toolbar = toolbar
    self.toolbarStyle = .unified
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
    LegacySecretChannel.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// Handles `readApiKey` on `stash_player/legacy_secret`: the API key the
/// SwiftUI client stored (a generic password, service `stash-player`,
/// account `stash-api-key`, in the file-based login keychain), nil when
/// there is none, or a `lookup-failed` error. Same bundle ID and team as
/// that client, so the item's access list admits this app without a prompt.
enum LegacySecretChannel {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "stash_player/legacy_secret",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "readApiKey" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "stash-player",
        kSecAttrAccount as String: "stash-api-key",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      switch status {
      case errSecSuccess:
        result((item as? Data).flatMap { String(data: $0, encoding: .utf8) })
      case errSecItemNotFound:
        result(nil)
      default:
        result(FlutterError(
          code: "lookup-failed",
          message: "SecItemCopyMatching returned \(status)",
          details: nil
        ))
      }
    }
  }
}
