import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Flutter owns all UI state; there's nothing useful for AppKit to
    // restore here, and macOS's window-state-restoration has been replaying
    // a stale/corrupted frame (observed as "Host window width is 0" in the
    // unified log) after the many force-kills during dev iteration today,
    // leaving the window blank on relaunch. Opting out avoids that class of
    // bug outright rather than just working around today's corrupted state.
    self.isRestorable = false

    RegisterGeneratedPlugins(registry: flutterViewController)
    PasskeyBridge.register(with: flutterViewController)

    super.awakeFromNib()
  }
}
