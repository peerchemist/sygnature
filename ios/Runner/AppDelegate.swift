import Flutter
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import BackgroundTasks
import workmanager_apple
import flutter_local_notifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let publicFeedRefreshTask =
    "network.noosphere.sygnature.public-feed"
  private var apnsChannel: FlutterMethodChannel?
  private var clipboardChannel: FlutterMethodChannel?
  #if targetEnvironment(simulator)
  private var publicFeedQAWindow: UIBackgroundTaskIdentifier = .invalid
  #endif

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: AppDelegate.publicFeedRefreshTask,
      earliestBeginInSeconds: NSNumber(value: 60 * 60)
    )
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      // path_provider_foundation 2.6 uses Dart FFI and its Dart registrant;
      // it has no native PathProviderPlugin to register in this version.
      if let registrar = registry.registrar(forPlugin: "FlutterLocalNotificationsPlugin") {
        FlutterLocalNotificationsPlugin.register(with: registrar)
      }
      AppDelegate.registerPublicFeedStorage(with: registry)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    Self.registerPublicFeedStorage(with: engineBridge.pluginRegistry)
    #if targetEnvironment(simulator)
    // Opt-in QA only: a finite UIKit execution window, never a simulated OS wake.
    if ProcessInfo.processInfo.environment["SYGNATURE_PUBLIC_FEED_QA"] == "1",
      let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SygnaturePublicFeedQA") {
      let channel = FlutterMethodChannel(name: "network.noosphere.sygnature/public-feed-qa",
        binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self else { return }
        switch call.method {
        case "beginWindow":
          self.publicFeedQAWindow = UIApplication.shared.beginBackgroundTask(withName: "PublicFeedQA") {
            UIApplication.shared.endBackgroundTask(self.publicFeedQAWindow)
            self.publicFeedQAWindow = .invalid
          }
          result(self.publicFeedQAWindow != .invalid)
        case "schedulerAvailability":
          do {
            try BGTaskScheduler.shared.submit(BGAppRefreshTaskRequest(
              identifier: Self.publicFeedRefreshTask))
            result(["accepted": true])
          } catch {
            let failure = error as NSError
            result(["accepted": false, "domain": failure.domain, "code": failure.code])
          }
        case "state":
          result(["applicationState": UIApplication.shared.applicationState.rawValue,
            "executionWindow": self.publicFeedQAWindow != .invalid])
        case "endWindow":
          if self.publicFeedQAWindow != .invalid {
            UIApplication.shared.endBackgroundTask(self.publicFeedQAWindow)
            self.publicFeedQAWindow = .invalid
          }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    #endif

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

  private static func registerPublicFeedStorage(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "SygnaturePublicFeedStorage") else { return }
    let channel = FlutterMethodChannel(
      name: "network.noosphere.sygnature/public-feed-storage",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "prepare" else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        let files = FileManager.default
        guard let arguments = call.arguments as? [String: Any],
          let path = arguments["directory"] as? String else {
          result(FlutterError(code: "INVALID_STORAGE_DIRECTORY",
            message: "Missing storage directory", details: nil))
          return
        }
        let support = URL(fileURLWithPath: path, isDirectory: true)
        let directory = support.appendingPathComponent("public-feed", isDirectory: true)
        let attributes: [FileAttributeKey: Any] = [
          .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
        // All new Hive files (including lock and compaction files) inherit this.
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
          attributes: attributes)
        try files.setAttributes(attributes, ofItemAtPath: directory.path)
        let prefix = "sygnature_public_feed_v1."
        for file in try files.contentsOfDirectory(at: directory,
          includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix(prefix) {
          try files.setAttributes(attributes, ofItemAtPath: file.path)
        }
        result(directory.path)
      } catch {
        // Do not return paths, capabilities or underlying native error text.
        result(FlutterError(code: "PUBLIC_FEED_STORAGE_UNAVAILABLE",
          message: "Public feed storage unavailable", details: nil))
      }
    }
  }

}
