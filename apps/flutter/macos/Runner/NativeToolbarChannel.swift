import Cocoa
import FlutterMacOS

/// Fills the window's toolbar from the spec `ChannelNativeToolbar` sends
/// over `stash_player/toolbar`, and reports clicks, menu choices and
/// search edits back.
///
/// Items are keyed by their Dart id. When a new spec has the same ids and
/// kinds in the same order, which is every filter change, each item is
/// updated in place, so the toolbar never flickers. Anything else (the
/// library appearing or leaving) rebuilds the item list.
final class NativeToolbarChannel: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private weak var view: NSView?
  /// Every item's spec by id, group children included.
  private var specs: [String: [String: Any]] = [:]
  /// Top-level ids, leading to trailing.
  private var order: [String] = []
  /// "kind:id" for every item, children included: equal fingerprints
  /// mean an in-place update is enough.
  private var structure: [String] = []
  private var items: [String: NSToolbarItem] = [:]

  init(messenger: FlutterBinaryMessenger, window: NSWindow, view: NSView) {
    self.window = window
    self.view = view
    channel = FlutterMethodChannel(name: "stash_player/toolbar", binaryMessenger: messenger)
    super.init()
    window.toolbar?.delegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    switch call.method {
    case "setItems":
      guard let list = call.arguments as? [[String: Any]] else {
        result(FlutterError(code: "bad-args", message: "setItems needs a list of items", details: nil))
        return
      }
      guard window?.toolbar != nil else {
        result(FlutterError(code: "no-toolbar", message: "the window has no toolbar", details: nil))
        return
      }
      apply(list)
      result(nil)
    case "reset":
      apply([])
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func apply(_ list: [[String: Any]]) {
    guard let toolbar = window?.toolbar else { return }
    var newSpecs: [String: [String: Any]] = [:]
    var newStructure: [String] = []
    func index(_ spec: [String: Any]) {
      guard let id = spec["id"] as? String else { return }
      newSpecs[id] = spec
      newStructure.append("\(spec["type"] as? String ?? ""):\(id)")
      for child in spec["children"] as? [[String: Any]] ?? [] {
        index(child)
      }
    }
    let newOrder = list.compactMap { $0["id"] as? String }
    list.forEach(index)
    specs = newSpecs

    if newStructure == structure {
      for (id, item) in items {
        if let spec = specs[id] { update(item, with: spec) }
      }
      return
    }

    structure = newStructure
    order = newOrder
    while !toolbar.items.isEmpty {
      toolbar.removeItem(at: 0)
    }
    items = [:]
    for (position, id) in newOrder.enumerated() {
      let identifier: NSToolbarItem.Identifier =
        specs[id]?["type"] as? String == "space" ? .flexibleSpace : NSToolbarItem.Identifier(id)
      toolbar.insertItem(withItemIdentifier: identifier, at: position)
    }
  }

  // MARK: NSToolbarDelegate

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    []
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    order.map { NSToolbarItem.Identifier($0) } + [.flexibleSpace]
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard let spec = specs[itemIdentifier.rawValue] else { return nil }
    return makeItem(spec)
  }

  // MARK: Items

  private func makeItem(_ spec: [String: Any]) -> NSToolbarItem? {
    guard let id = spec["id"] as? String else { return nil }
    let identifier = NSToolbarItem.Identifier(id)
    let item: NSToolbarItem
    switch spec["type"] as? String {
    case "menu":
      let menuItem = NSMenuToolbarItem(itemIdentifier: identifier)
      menuItem.showsIndicator = true
      item = menuItem
    case "toggle":
      // A toolbar item has no on/off state of its own, so a toggle is a
      // push-on/push-off button in the toolbar's own bezel.
      item = NSToolbarItem(itemIdentifier: identifier)
      let button = NSButton(frame: .zero)
      button.bezelStyle = .toolbar
      button.setButtonType(.pushOnPushOff)
      button.imagePosition = .imageOnly
      button.identifier = NSUserInterfaceItemIdentifier(id)
      button.target = self
      button.action = #selector(activate(_:))
      item.view = button
    case "action":
      item = NSToolbarItem(itemIdentifier: identifier)
      item.isBordered = true
      item.autovalidates = false
      item.target = self
      item.action = #selector(activate(_:))
    case "search":
      let search = NSSearchToolbarItem(itemIdentifier: identifier)
      search.searchField.identifier = NSUserInterfaceItemIdentifier(id)
      search.searchField.delegate = self
      // The cancel (x) button clears the field through its action rather
      // than a text change.
      search.searchField.target = self
      search.searchField.action = #selector(searchAction(_:))
      item = search
    case "group":
      let group = NSToolbarItemGroup(itemIdentifier: identifier)
      group.subitems = (spec["children"] as? [[String: Any]] ?? []).compactMap(makeItem)
      item = group
    default:
      return nil
    }
    items[id] = item
    update(item, with: spec)
    return item
  }

  private func update(_ item: NSToolbarItem, with spec: [String: Any]) {
    let label = spec["label"] as? String ?? ""
    item.label = label
    item.paletteLabel = label
    item.toolTip = spec["tooltip"] as? String
    let image = (spec["symbol"] as? String).flatMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: label)
    }
    switch spec["type"] as? String {
    case "menu":
      guard let menuItem = item as? NSMenuToolbarItem else { return }
      let options = spec["options"] as? [String] ?? []
      let selected = spec["selected"] as? Int ?? -1
      let menu = NSMenu()
      for (index, option) in options.enumerated() {
        let entry = NSMenuItem(title: option, action: #selector(selectOption(_:)), keyEquivalent: "")
        entry.target = self
        entry.tag = index
        entry.representedObject = spec["id"] as? String
        entry.state = index == selected ? .on : .off
        menu.addItem(entry)
      }
      menuItem.menu = menu
      menuItem.title = options.indices.contains(selected) ? options[selected] : label
    case "toggle":
      guard let button = item.view as? NSButton else { return }
      button.image = image
      button.state = spec["selected"] as? Bool == true ? .on : .off
      button.toolTip = item.toolTip
      button.setAccessibilityLabel(label)
    case "action":
      let badged = spec["badge"] as? Bool == true
      item.image = badgeFallbackImage(spec, badged: badged) ?? image
      item.isEnabled = spec["enabled"] as? Bool ?? true
      applyBadge(item, badged)
    case "search":
      guard let search = item as? NSSearchToolbarItem else { return }
      search.searchField.placeholderString = spec["placeholder"] as? String
      let text = spec["text"] as? String ?? ""
      if !isEditing(search.searchField), search.searchField.stringValue != text {
        search.searchField.stringValue = text
      }
    default:
      break
    }
  }

  /// The system badge dot, on macOS 26 and later.
  private func applyBadge(_ item: NSToolbarItem, _ on: Bool) {
    #if compiler(>=6.2)
      if #available(macOS 26.0, *) {
        item.badge = on ? .indicator : nil
      }
    #endif
  }

  /// Before macOS 26 there is no badge, so a badged item shows the filled
  /// variant of its symbol instead. Nil when the item isn't badged, or
  /// when the system badge covers it.
  private func badgeFallbackImage(_ spec: [String: Any], badged: Bool) -> NSImage? {
    guard badged, let symbol = spec["symbol"] as? String else { return nil }
    #if compiler(>=6.2)
      if #available(macOS 26.0, *) { return nil }
    #endif
    return NSImage(
      systemSymbolName: "\(symbol).fill",
      accessibilityDescription: spec["label"] as? String
    )
  }

  private func isEditing(_ field: NSTextField) -> Bool {
    guard let editor = field.currentEditor() else { return false }
    return window?.firstResponder === editor
  }

  // MARK: Events

  @objc private func activate(_ sender: Any) {
    let id: String?
    if let button = sender as? NSButton {
      id = button.identifier?.rawValue
    } else if let item = sender as? NSToolbarItem {
      id = item.itemIdentifier.rawValue
    } else {
      id = nil
    }
    guard let id else { return }
    var args: [String: Any] = ["id": id]
    if let rect = clickAnchor() { args["rect"] = rect }
    channel.invokeMethod("activated", arguments: args)
  }

  /// Where the click that chose an item landed: a titlebar-high strip at
  /// that x, in the Flutter view's top-left coordinates, for anchoring a
  /// drawn popover under the item. Nil when there was no click in this
  /// window (the overflow menu, the keyboard); Dart then picks the
  /// trailing edge.
  private func clickAnchor() -> [String: Double]? {
    guard let view, let window, let event = NSApp.currentEvent,
      event.window === window,
      event.type == .leftMouseUp || event.type == .leftMouseDown
    else { return nil }
    let point = view.convert(event.locationInWindow, from: nil)
    let titlebar = window.frame.height - window.contentLayoutRect.height
    return ["x": Double(point.x) - 14, "y": 0, "width": 28, "height": Double(titlebar)]
  }

  @objc private func selectOption(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    channel.invokeMethod("menuSelected", arguments: ["id": id, "index": sender.tag])
  }

  @objc private func searchAction(_ sender: NSSearchField) {
    sendSearch(sender)
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField else { return }
    sendSearch(field)
  }

  private func sendSearch(_ field: NSSearchField) {
    guard let id = field.identifier?.rawValue else { return }
    channel.invokeMethod("searchChanged", arguments: ["id": id, "text": field.stringValue])
  }
}
