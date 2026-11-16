import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// The links channel (lib/services/deep_link_service.dart), and the
  /// zestssh:// links that came before the app asked for them
  /// ("getInitialLink", as it starts listening): the first is the one it
  /// opens with, the rest follow it ("onDeepLink"). A Mac had no zestssh://
  /// scheme (Info.plist) and nothing taking a link, so no link reached the
  /// app there. macOS runs one copy of the app: a link opened while it runs
  /// comes to this one, as an Apple event.
  private var deepLinkChannel: FlutterMethodChannel?
  private var earlyLinks: [String] = []
  private var linkAsked = false

  /// Links kept before the app asks: a few, as the app itself keeps.
  private let maxEarlyLinks = 8

  /// The Mac's own passkeys (4.0), on zestssh/passkeys (PasskeyChannel.swift).
  private var passkeys: PasskeyChannel?

  /// Relative mouse on a remote screen (4.0), on zestssh/pointer_capture
  /// (PointerCaptureChannel.swift): this window's pointer held, and given back.
  private var pointerCapture: PointerCaptureChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // What the keychain's readAll cannot do in the legacy keychain.
    KeychainNames.register(with: flutterViewController.engine.binaryMessenger)

    // Passkeys made and used in the app, where this build may ask for them
    // (a signed build with the associated domains entitlement); the sheet
    // hangs on this window.
    passkeys = PasskeyChannel(messenger: flutterViewController.engine.binaryMessenger) { [weak self] in
      self
    }

    // Relative mouse: the pointer is held for this window only.
    pointerCapture = PointerCaptureChannel(messenger: flutterViewController.engine.binaryMessenger) { [weak self] in
      self
    }

    // The Secure Enclave, for the vault's hardware layer.
    SecureEnclaveChannel.register(with: flutterViewController.engine.binaryMessenger)

    let links = FlutterMethodChannel(
      name: "com.affluentlabs.zestssh/deeplink",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    links.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self, call.method == "getInitialLink" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.linkAsked = true
      let early = self.earlyLinks
      self.earlyLinks = []
      result(early.first)
      for link in early.dropFirst() {
        self.deepLinkChannel?.invokeMethod("onDeepLink", arguments: link)
      }
    }
    deepLinkChannel = links
    // Here, before the app finishes launching: the link a click started it
    // for comes as an Apple event right after, and is not lost.
    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleGetURL(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL))

    // Native trash: FileManager.trashItem lands a local delete in the macOS
    // Trash (recoverable, with Put Back) instead of unlinking it - the Recycle
    // Bin equivalent used by the SFTP delete-safety flow. Returns true only when
    // every path was trashed; the Dart side falls back to the hold window
    // otherwise.
    let trashChannel = FlutterMethodChannel(
      name: "zestssh/native_trash",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    trashChannel.setMethodCallHandler { (call, result) in
      guard call.method == "trash",
            let args = call.arguments as? [String: Any],
            let paths = args["paths"] as? [String] else {
        result(FlutterMethodNotImplemented)
        return
      }
      let fm = FileManager.default
      var allOk = true
      for path in paths {
        do {
          try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
          allOk = false
        }
      }
      result(allOk)
    }

    super.awakeFromNib()
  }

  /// A zestssh:// link opened (a browser, another app): to the app, which
  /// reads it as strictly as on every device and asks before anything is
  /// added or run; the window to the front where the app is running.
  @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
    guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
          let url = URL(string: text), url.scheme?.lowercased() == "zestssh" else {
      return
    }
    if linkAsked, let channel = deepLinkChannel {
      if isMiniaturized {
        deminiaturize(nil)
      }
      makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      channel.invokeMethod("onDeepLink", arguments: text)
    } else if earlyLinks.count < maxEarlyLinks {
      earlyLinks.append(text)
    }
  }
}
