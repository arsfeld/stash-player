import Cocoa
import FlutterMacOS
import Sparkle

@main
class AppDelegate: FlutterAppDelegate {
  // Starts the updater immediately: scheduled background checks follow
  // SUEnableAutomaticChecks in Info.plist (then the user's choice in
  // Sparkle's own dialog), and the menu item below triggers a manual check.
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  // Target of the "Check for Updates…" item in MainMenu.xib, which sends
  // this action to the first responder; the app delegate is on that chain.
  @IBAction func checkForUpdates(_ sender: Any?) {
    updaterController.checkForUpdates(sender)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
