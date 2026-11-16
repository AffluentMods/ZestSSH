import Flutter
import UIKit
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var methodChannel: FlutterMethodChannel?

  /// The zestssh:// link the app was opened with, until the app asks for it
  /// (DeepLinkService.init, "getInitialLink"), and whether it has asked:
  /// a link that comes before then is the one it opens with (iOS hands a
  /// link to both the launch and to `open url` when it starts the app for
  /// it, and the app has nothing listening for links yet).
  private var initialLink: String?
  private var linkAsked = false

  /// The phone's own passkeys (3.3), on zestssh/passkeys (PasskeyChannel.swift).
  private var passkeys: PasskeyChannel?

  /// A FIDO2 security key held to the iPhone (4.0), on zestssh/fido
  /// (FidoChannel.swift): for an SSH key that lives on one.
  private var fido: FidoChannel?

  /// A little time in the background (4.0, remote screens), on
  /// com.affluentlabs.zestssh/background (lib/services/background_grace.dart):
  /// the app's remote screens are closed cleanly before iOS suspends it.
  private var backgroundChannel: FlutterMethodChannel?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

  /// The home screen widget (4.0, ios/ZestSSHWidget), on
  /// com.affluentlabs.zestssh/widget (lib/services/widget_service.dart).
  private var widgetChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let url = launchOptions?[.url] as? URL, url.scheme == "zestssh" {
      initialLink = url.absoluteString
    }

    // The links channel (lib/services/deep_link_service.dart). It was set up
    // with nothing answering it, and no link opened while the app ran was
    // handed on, so no zestssh:// link ever reached the app on an iPhone or
    // an iPad: not one that opens a host, shares one, or runs automation.
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "com.affluentlabs.zestssh/deeplink",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "getInitialLink":
          // Handed over once.
          self?.linkAsked = true
          result(self?.initialLink)
          self?.initialLink = nil
        case "getInitialAutomation":
          // Android's intents only; Shortcuts hand over below.
          result(nil)
        case "setAutomationResult":
          // No app on iOS waits for what a run printed.
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      methodChannel = channel

      // Passkeys: the system's sheet over the app's window.
      passkeys = PasskeyChannel(messenger: controller.binaryMessenger) { [weak self] in
        self?.passkeyAnchor()
      }

      // A security key held near the top of the iPhone: bytes to it and back.
      fido = FidoChannel(messenger: controller.binaryMessenger)

      // Time to finish in the background: begun as the app leaves the
      // screen with a remote screen open, ended when it is back or done.
      let background = FlutterMethodChannel(
        name: "com.affluentlabs.zestssh/background",
        binaryMessenger: controller.binaryMessenger
      )
      background.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "begin":
          result(self?.beginBackgroundGrace())
        case "end":
          self?.endBackgroundGrace()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      backgroundChannel = background

      // The widget's data: what the app gives it (a host's id, name and
      // address, or only that the app is locked) is kept in the App Group
      // the widget reads, and the widget reloaded.
      let widget = FlutterMethodChannel(
        name: "com.affluentlabs.zestssh/widget",
        binaryMessenger: controller.binaryMessenger
      )
      widget.setMethodCallHandler { call, result in
        switch call.method {
        case "setWidgetData":
          guard let json = call.arguments as? String else {
            result(FlutterError(code: "bad_args", message: "setWidgetData takes a JSON string", details: nil))
            return
          }
          result(AppDelegate.setWidgetData(json))
        case "reloadWidgets":
          WidgetCenter.shared.reloadAllTimelines()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      widgetChannel = widget
    }

    // Check for pending automation from Shortcuts
    checkPendingAutomation()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Asks iOS for time to finish in the background: the seconds it gives, or
  /// nil when it gives none. Out of time, the app is told ("expired") and the
  /// task ends, so iOS never ends the app for holding it.
  private func beginBackgroundGrace() -> Double? {
    if backgroundTask == .invalid {
      backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ZestSSH remote screens") { [weak self] in
        self?.backgroundChannel?.invokeMethod("expired", arguments: nil)
        self?.endBackgroundGrace()
      }
    }
    if backgroundTask == .invalid { return nil }
    let left = UIApplication.shared.backgroundTimeRemaining
    // Still in front, iOS says there is no limit (the largest Double): the
    // usual grace, which the app's own timer then keeps to.
    return left.isFinite && left < 3600 ? left : 30
  }

  private func endBackgroundGrace() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  /// The window a passkey sheet is shown over: the key window of the scene in
  /// front, else the app's own.
  private func passkeyAnchor() -> UIWindow? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let key = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow {
      return key
    }
    return window
  }

  /// A zestssh:// link opened while the app runs goes to the app; any other
  /// (a sign-in's return, which plugins take) goes on as before.
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.scheme == "zestssh" {
      if linkAsked, let channel = methodChannel {
        channel.invokeMethod("onDeepLink", arguments: url.absoluteString)
      } else {
        initialLink = url.absoluteString
      }
      return true
    }
    return super.application(app, open: url, options: options)
  }

  /// The App Group the app and its widget share: ZEST_APP_GROUP in the Xcode
  /// project, carried to Info.plist as ZestAppGroup.
  static var appGroup: String {
    (Bundle.main.object(forInfoDictionaryKey: "ZestAppGroup") as? String)
      .flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
      ?? "group.com.affluentlabs.zestssh"
  }

  /// Keeps [json] where the widget reads it and reloads the widget. False
  /// where the App Group is not there (the app was signed without it).
  private static func setWidgetData(_ json: String) -> Bool {
    guard let shared = UserDefaults(suiteName: appGroup),
          FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil else {
      return false
    }
    shared.set(json, forKey: "widget_data")
    WidgetCenter.shared.reloadAllTimelines()
    return true
  }

  /// What a Shortcuts action left in the shared defaults (ZestSSHIntents.swift
  /// writes it beside the zestssh://execute or zestssh://snippet link it
  /// opens) is cleared and never run from here. It went to the app as an
  /// automation intent ("onAutomation"), which an app on Android sends with
  /// its key and the app does not ask about: on a cold start a Shortcut's
  /// command went past the question every link gets ("Run this from a
  /// link?"). The link the action opens carries the same command and comes
  /// to the app as every link does (getInitialLink, onDeepLink), asked about
  /// first (DeepLinkService.extractAutomationParams), whether the app was
  /// running or not.
  private func checkPendingAutomation() {
    UserDefaults(suiteName: AppDelegate.appGroup)?.removeObject(forKey: "pending_automation")
  }
}
