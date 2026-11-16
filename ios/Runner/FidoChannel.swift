import CoreNFC
import Flutter
import UIKit

/// The iPhone's side of a FIDO2 security key (4.0): only what carries bytes.
///
/// A security key held near the top of the iPhone is an ISO 7816 card to
/// CoreNFC. The app asks for a session, the system shows its own sheet, and
/// each command goes to the key as one exchange. Everything that reads or
/// writes a meaning is in Dart (lib/services/fido/), where it is tested:
/// nothing here parses what a key sends.
///
/// The channel is "zestssh/fido" (lib/services/fido/fido_platform.dart).
/// Errors carry a code Dart knows: cancelled, unavailable, lost, timeout.
///
/// No USB: iOS gives an app no raw channel to a USB security key, and an
/// iPad has no NFC reader for apps. `ways` says so, and the app says it in
/// words.
///
/// The build needs the NFC Tag Reading capability (Runner.entitlements, and
/// the App ID and its profiles), NFCReaderUsageDescription, and the FIDO
/// applet's id among the ISO 7816 select identifiers (Info.plist).
final class FidoChannel: NSObject, NFCTagReaderSessionDelegate {
  private let channel: FlutterMethodChannel
  private var session: NFCTagReaderSession?
  private var tag: NFCISO7816Tag?
  private var waiting: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "zestssh/fido", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "ways":
      let nfc = NFCTagReaderSession.readingAvailable
      result(["nfc": nfc, "nfcOn": nfc, "usb": false])
    case "nfcBegin":
      begin(prompt: (call.arguments as? [String: Any])?["prompt"] as? String, result)
    case "nfcTransceive":
      transceive(call.arguments as? FlutterStandardTypedData, result)
    case "nfcEnd":
      end(error: (call.arguments as? [String: Any])?["error"] as? String)
      result(nil)
    case "usbOpen":
      result(false)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Waits for a security key near the phone: the system's sheet shows
  /// [prompt] until one comes, the person closes it, or a minute passes.
  private func begin(prompt: String?, _ result: @escaping FlutterResult) {
    guard NFCTagReaderSession.readingAvailable else {
      result(FlutterError(code: "unavailable", message: "this device has no NFC reader for apps", details: nil))
      return
    }
    if let before = waiting {
      waiting = nil
      before(FlutterError(code: "cancelled", message: "another wait took its place", details: nil))
    }
    end(error: nil)
    guard let made = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: DispatchQueue.main) else {
      result(FlutterError(code: "unavailable", message: "no NFC session could be made", details: nil))
      return
    }
    if let prompt = prompt, !prompt.isEmpty {
      made.alertMessage = prompt
    }
    waiting = result
    session = made
    made.begin()
  }

  func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

  /// The sheet is gone: the person closed it, a minute passed, or the app
  /// ended the session itself.
  func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
    var code = "lost"
    if let reader = error as? NFCReaderError {
      switch reader.code {
      case .readerSessionInvalidationErrorUserCanceled:
        code = "cancelled"
      case .readerSessionInvalidationErrorSessionTimeout:
        code = "timeout"
      default:
        code = "lost"
      }
    }
    if self.session === session {
      self.session = nil
      tag = nil
    }
    if let stillWaiting = waiting {
      waiting = nil
      stillWaiting(FlutterError(code: code, message: error.localizedDescription, details: nil))
    }
  }

  func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
    guard let first = tags.first, case let .iso7816(card) = first else {
      // Not an ISO 7816 card: not a security key. Keep looking.
      session.restartPolling()
      return
    }
    session.connect(to: first) { [weak self] error in
      guard let self = self, self.session === session else { return }
      if error != nil {
        // It left again at once: keep looking.
        session.restartPolling()
        return
      }
      self.tag = card
      if let stillWaiting = self.waiting {
        self.waiting = nil
        stillWaiting(nil)
      }
    }
  }

  /// One command to the key, and its answer with the two status bytes after
  /// it, as an ISO 7816-4 answer is.
  private func transceive(_ data: FlutterStandardTypedData?, _ result: @escaping FlutterResult) {
    guard let card = tag, let bytes = data?.data, let apdu = NFCISO7816APDU(data: bytes) else {
      result(FlutterError(code: "lost", message: "no security key is near the phone", details: nil))
      return
    }
    card.sendCommand(apdu: apdu) { answer, sw1, sw2, error in
      if let error = error {
        // The key moved away.
        result(FlutterError(code: "lost", message: error.localizedDescription, details: nil))
        return
      }
      var out = Data(answer)
      out.append(sw1)
      out.append(sw2)
      result(FlutterStandardTypedData(bytes: out))
    }
  }

  /// Ends the session and its sheet; with [error] the sheet says it first.
  private func end(error: String?) {
    guard let current = session else { return }
    session = nil
    tag = nil
    if let error = error, !error.isEmpty {
      current.invalidate(errorMessage: error)
    } else {
      current.invalidate()
    }
  }
}
