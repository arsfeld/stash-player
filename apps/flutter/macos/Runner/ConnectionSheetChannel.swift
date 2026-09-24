import Cocoa
import FlutterMacOS

/// The connection form as a real AppKit sheet, over
/// `stash_player/connection_sheet`. Dart (`ConnectionSheetPresenter`)
/// owns every rule: this only lays out the fields, reports edits, submit
/// and cancel, and shows the state Dart sends back.
final class ConnectionSheetChannel: NSObject, NSTextFieldDelegate {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var panel: NSPanel?
  private var content: ConnectionSheetContent?
  private var wasBusy = false

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    self.window = window
    channel = FlutterMethodChannel(name: "stash_player/connection_sheet", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    switch call.method {
    case "present":
      guard panel == nil else {
        result(FlutterError(code: "already-open", message: "a connection sheet is already open", details: nil))
        return
      }
      guard let window, let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad-args", message: "present needs a window and arguments", details: nil))
        return
      }
      present(args, over: window)
      result(nil)
    case "update":
      if let args = call.arguments as? [String: Any] { update(args) }
      result(nil)
    case "dismiss", "reset":
      dismiss()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func present(_ args: [String: Any], over window: NSWindow) {
    let content = ConnectionSheetContent(
      title: args["title"] as? String ?? "",
      confirmLabel: args["confirmLabel"] as? String ?? "OK",
      cancellable: args["cancellable"] as? Bool ?? true,
      proxyHint: args["proxyHint"] as? String ?? "",
      target: self
    )
    content.urlField.stringValue = args["serverUrl"] as? String ?? ""
    content.apiKeyField.stringValue = args["apiKey"] as? String ?? ""
    content.proxyField.stringValue = args["socksProxy"] as? String ?? ""
    for field in content.fields { field.delegate = self }

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    panel.contentView = content.root
    panel.setContentSize(content.root.fittingSize)
    panel.initialFirstResponder = content.urlField
    self.panel = panel
    self.content = content
    wasBusy = false
    window.beginSheet(panel)
  }

  private func update(_ args: [String: Any]) {
    guard let content, let panel else { return }
    let busy = args["busy"] as? Bool ?? false
    let canSubmit = args["canSubmit"] as? Bool ?? false
    content.confirm.isEnabled = canSubmit && !busy
    content.cancel?.isEnabled = !busy
    for field in content.fields { field.isEnabled = !busy }
    if busy {
      content.spinner.startAnimation(nil)
    } else {
      content.spinner.stopAnimation(nil)
    }
    content.show(args["urlError"] as? String, in: content.urlError)
    content.show(args["proxyError"] as? String, in: content.proxyError)
    content.show(args["failure"] as? String, in: content.failure)
    panel.setContentSize(content.root.fittingSize)
    // A failed test re-enables the fields; put the cursor back where the
    // user will fix the entry.
    if wasBusy && !busy {
      panel.makeFirstResponder(content.urlField)
    }
    wasBusy = busy
  }

  private func dismiss() {
    guard let panel else { return }
    (panel.sheetParent ?? window)?.endSheet(panel)
    self.panel = nil
    content = nil
  }

  // MARK: Events

  @objc func confirmPressed(_ sender: Any?) {
    send("submitted")
  }

  @objc func cancelPressed(_ sender: Any?) {
    channel.invokeMethod("cancelled", arguments: nil)
  }

  func controlTextDidChange(_ notification: Notification) {
    send("changed")
  }

  private func send(_ method: String) {
    guard let content else { return }
    channel.invokeMethod(method, arguments: [
      "serverUrl": content.urlField.stringValue,
      "apiKey": content.apiKeyField.stringValue,
      "socksProxy": content.proxyField.stringValue,
    ])
  }
}

/// The sheet's views, built fresh for each presentation.
///
/// Every view is built as a local and assigned at the end of `init`:
/// Swift forbids reading `self` before all stored properties are set.
private final class ConnectionSheetContent {
  let root: NSView
  let urlField: NSTextField
  let apiKeyField: NSSecureTextField
  let proxyField: NSTextField
  let urlError: NSTextField
  let proxyError: NSTextField
  let failure: NSTextField
  let spinner: NSProgressIndicator
  let confirm: NSButton
  let cancel: NSButton?
  private let grid: NSGridView

  var fields: [NSTextField] { [urlField, apiKeyField, proxyField] }

  init(title: String, confirmLabel: String, cancellable: Bool, proxyHint: String, target: ConnectionSheetChannel) {
    let urlField = NSTextField()
    urlField.placeholderString = "https://stash.example.com"
    let apiKeyField = NSSecureTextField()
    apiKeyField.placeholderString = "Optional"
    let proxyField = NSTextField()
    proxyField.placeholderString = "Optional"
    for field in [urlField, apiKeyField, proxyField] {
      field.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
    }

    let urlError = Self.messageLabel(color: .systemRed)
    let proxyError = Self.messageLabel(color: .systemRed)
    let failure = Self.messageLabel(color: .systemRed)
    failure.isHidden = true
    let hint = Self.messageLabel(color: .secondaryLabelColor)
    hint.stringValue = proxyHint

    let heading = NSTextField(labelWithString: title)
    heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

    // Messages get rows of their own, so the label/field rows can align
    // on the first baseline and an empty message row can be hidden.
    let grid = NSGridView(views: [
      [Self.fieldLabel("Server URL:"), urlField],
      [NSGridCell.emptyContentView, urlError],
      [Self.fieldLabel("API Key:"), apiKeyField],
      [Self.fieldLabel("SOCKS5 Proxy:"), proxyField],
      [NSGridCell.emptyContentView, proxyError],
      [NSGridCell.emptyContentView, hint],
    ])
    grid.rowSpacing = 8
    grid.columnSpacing = 8
    grid.rowAlignment = .firstBaseline
    grid.column(at: 0).xPlacement = .trailing
    grid.row(at: 1).isHidden = true
    grid.row(at: 4).isHidden = true

    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false

    let confirm = NSButton(
      title: confirmLabel, target: target, action: #selector(ConnectionSheetChannel.confirmPressed(_:)))
    // Return: the default button, drawn in the accent colour.
    confirm.keyEquivalent = "\r"
    confirm.isEnabled = false
    var cancel: NSButton?
    if cancellable {
      let button = NSButton(
        title: "Cancel", target: target, action: #selector(ConnectionSheetChannel.cancelPressed(_:)))
      button.keyEquivalent = "\u{1b}"
      cancel = button
    }

    let buttons = NSStackView()
    buttons.orientation = .horizontal
    buttons.spacing = 8
    buttons.setViews([spinner] + [cancel, confirm].compactMap { $0 }, in: .trailing)

    let stack = NSStackView(views: [heading, grid, failure, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

    self.root = stack
    self.urlField = urlField
    self.apiKeyField = apiKeyField
    self.proxyField = proxyField
    self.urlError = urlError
    self.proxyError = proxyError
    self.failure = failure
    self.spinner = spinner
    self.confirm = confirm
    self.cancel = cancel
    self.grid = grid
  }

  /// Shows [message] in [label], or hides it (and its grid row) when nil.
  func show(_ message: String?, in label: NSTextField) {
    label.stringValue = message ?? ""
    let hidden = message == nil
    if label === failure {
      label.isHidden = hidden
    } else if let row = rowIndex(of: label) {
      grid.row(at: row).isHidden = hidden
    }
  }

  private func rowIndex(of view: NSView) -> Int? {
    (0..<grid.numberOfRows).first { grid.cell(atColumnIndex: 1, rowIndex: $0).contentView === view }
  }

  private static func fieldLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.alignment = .right
    return label
  }

  private static func messageLabel(color: NSColor) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: "")
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = color
    label.preferredMaxLayoutWidth = 280
    return label
  }
}
