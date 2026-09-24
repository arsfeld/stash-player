import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // Retained for the window's lifetime: FlutterEventChannel holds its
  // handler weakly.
  private let appearance = AppearanceStreamHandler()
  private var nativeMenus: NativeMenuChannel?

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
    FlutterEventChannel(
      name: "stash_player/appearance",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setStreamHandler(appearance)
    nativeMenus = NativeMenuChannel(
      messenger: flutterViewController.engine.binaryMessenger,
      view: flutterViewController.view
    )
    UpdatesChannel.register(with: flutterViewController.engine.binaryMessenger)

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

/// Streams the system accent colour on `stash_player/appearance`, once on
/// listen and again whenever the user changes it in System Settings.
/// `fontName` is always nil: the app always uses the system font on macOS.
final class AppearanceStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var observer: NSObjectProtocol?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    sink = events
    send()
    observer = NotificationCenter.default.addObserver(
      forName: NSColor.systemColorsDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.send() }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    sink = nil
    return nil
  }

  private func send() {
    guard let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
      let event: [String: Any] = ["accent": NSNull(), "fontName": NSNull()]
      sink?(event)
      return
    }
    func channel(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
    let argb = (0xFF << 24) | (channel(color.redComponent) << 16)
      | (channel(color.greenComponent) << 8) | channel(color.blueComponent)
    let event: [String: Any] = ["accent": argb, "fontName": NSNull()]
    sink?(event)
  }
}

/// Shows the menus Dart describes on `stash_player/menu` as real `NSMenu`
/// popups, and answers with the chosen item's id (nil when dismissed).
final class NativeMenuChannel: NSObject {
  private weak var view: NSView?
  private var chosen: Int?
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger, view: NSView) {
    self.view = view
    channel = FlutterMethodChannel(name: "stash_player/menu", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    guard call.method == "show" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let view else {
      result(FlutterError(code: "no-window", message: "the Flutter view is not available", details: nil))
      return
    }
    guard let args = call.arguments as? [String: Any],
      let anchor = args["anchor"] as? [String: Double],
      let items = args["items"] as? [[String: Any]]
    else {
      result(FlutterError(code: "bad-args", message: "show needs anchor and items", details: nil))
      return
    }

    let menu = NSMenu()
    menu.autoenablesItems = false
    for item in items {
      if item["type"] as? String == "separator" {
        menu.addItem(.separator())
        continue
      }
      let entry = NSMenuItem(
        title: item["label"] as? String ?? "",
        action: #selector(select(_:)),
        keyEquivalent: ""
      )
      entry.target = self
      entry.tag = item["id"] as? Int ?? -1
      entry.isEnabled = item["enabled"] as? Bool ?? true
      if let checked = item["checked"] as? Bool {
        entry.state = checked ? .on : .off
      }
      menu.addItem(entry)
    }

    // Flutter's anchor is top-left-origin; AppKit views are usually
    // bottom-left. The menu's top-left corner goes at the anchor's
    // bottom-left.
    let bottom = (anchor["y"] ?? 0) + (anchor["height"] ?? 0)
    let point = NSPoint(
      x: anchor["x"] ?? 0,
      y: view.isFlipped ? bottom : view.bounds.height - bottom
    )
    chosen = nil
    // popUp runs its own tracking loop and only returns once the menu has
    // closed, so `chosen` is final by the next line.
    menu.popUp(positioning: nil, at: point, in: view)
    result(chosen)
  }

  @objc private func select(_ sender: NSMenuItem) {
    chosen = sender.tag
  }
}

/// Runs Sparkle's "Check for Updates…" when the Dart menu bar asks, over
/// `stash_player/updates`. The menu bar itself is built in Dart
/// (`app_menu_bar.dart`), which replaces the one MainMenu.xib loads.
enum UpdatesChannel {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "stash_player/updates", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "checkForUpdates" else {
        result(FlutterMethodNotImplemented)
        return
      }
      (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil)
      result(nil)
    }
  }
}
