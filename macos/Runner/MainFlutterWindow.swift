import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var clipboardChannel: FlutterMethodChannel?
  private var clipboardExpiration: DispatchWorkItem?
  private var clipboardChangeCount: Int?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.clearSensitiveClipboard() }

    let registrar = flutterViewController.registrar(
      forPlugin: "SygnatureClipboard"
    )
    let channel = FlutterMethodChannel(
      name: "network.noosphere.sygnature/clipboard",
      binaryMessenger: registrar.messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "setSensitiveText",
        let arguments = call.arguments as? [String: Any],
        let text = arguments["text"] as? String,
        let milliseconds = arguments["expirationMilliseconds"] as? NSNumber
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.clipboardExpiration?.cancel()
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      guard pasteboard.setString(text, forType: .string) else {
        result(
          FlutterError(
            code: "clipboard_write_failed",
            message: "Unable to write the invitation to the clipboard.",
            details: nil
          )
        )
        return
      }
      self.clipboardChangeCount = pasteboard.changeCount
      let expiration = DispatchWorkItem { [weak self] in
        self?.clearSensitiveClipboard()
      }
      self.clipboardExpiration = expiration
      DispatchQueue.main.asyncAfter(
        deadline: .now() + .milliseconds(milliseconds.intValue),
        execute: expiration
      )
      result(nil)
    }
    clipboardChannel = channel

    super.awakeFromNib()
  }

  private func clearSensitiveClipboard() {
    clipboardExpiration?.cancel()
    clipboardExpiration = nil
    guard let clipboardChangeCount else { return }
    self.clipboardChangeCount = nil
    let pasteboard = NSPasteboard.general
    if pasteboard.changeCount == clipboardChangeCount {
      pasteboard.clearContents()
    }
  }
}
