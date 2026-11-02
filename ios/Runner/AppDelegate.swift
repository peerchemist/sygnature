import Flutter
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let publicFeedRefreshTask =
    "network.noosphere.sygnature.public-feed.refresh"
  private var apnsChannel: FlutterMethodChannel?
  private var clipboardChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: Self.publicFeedRefreshTask,
      earliestBeginInSeconds: NSNumber(value: 15 * 60)
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SygnatureClipboard"
    ) {
      let channel = FlutterMethodChannel(
        name: "network.noosphere.sygnature/clipboard",
        binaryMessenger: registrar.messenger()
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
        DispatchQueue.main.async {
          UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: text]],
            options: [
              .expirationDate: Date().addingTimeInterval(
                milliseconds.doubleValue / 1_000
              )
            ]
          )
          result(nil)
        }
      }
      clipboardChannel = channel
    }

    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SygnatureAPNs"
    ) else { return }
    let channel = FlutterMethodChannel(
      name: "network.noosphere.sygnature/apns",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "register" else {
        result(FlutterMethodNotImplemented)
        return
      }
      // Notification authorization is requested in Dart before this call.
      // The token is intentionally not logged or placed in a notification.
      DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
        result(nil)
      }
    }
    apnsChannel = channel
  }
}
