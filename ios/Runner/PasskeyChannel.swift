import AuthenticationServices
import Flutter
import UIKit

/// The phone's own passkeys (3.3; the two-step contract, section 4), on the
/// channel zestssh/passkeys (lib/services/passkeys/channel_passkeys.dart):
/// AuthenticationServices makes and uses them, a passkey of iCloud Keychain
/// (or of the person's password manager), one on a phone nearby, or a
/// security key, for zestssh.com, which names this app
/// (webcredentials:zestssh.com in Runner.entitlements, and
/// zestssh.com/.well-known/apple-app-site-association). The origin in the
/// clientDataJSON the system writes is https://zestssh.com. iOS 16 or later;
/// the Mac app has none of this (it signs in through the browser).
///
/// ZestSSH Cloud's options come in as JSON text; the response goes back as
/// JSON text built from the credential the system hands over, in base64url
/// without padding, as the server reads it. A failure is answered as an
/// error whose code the Dart side knows (cancelled, no-credential,
/// invalid-state, security, unsupported, failed), with the system's own
/// words for it as the message, for Copy details.
final class PasskeyChannel: NSObject {
  static let name = "zestssh/passkeys"

  private let channel: FlutterMethodChannel
  private let anchor: () -> UIWindow?

  /// The ceremony under way (the system's controller holds its delegate
  /// weakly, so it is held here until it ends).
  private var pending: AnyObject?

  init(messenger: FlutterBinaryMessenger, anchor: @escaping () -> UIWindow?) {
    channel = FlutterMethodChannel(name: PasskeyChannel.name, binaryMessenger: messenger)
    self.anchor = anchor
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      if #available(iOS 16.0, *) {
        result(true)
      } else {
        result(false)
      }
    case "create", "get":
      guard #available(iOS 16.0, *) else {
        result(FlutterError(code: "unsupported", message: "iOS \(UIDevice.current.systemVersion)", details: nil))
        return
      }
      guard pending == nil else {
        result(FlutterError(code: "failed", message: "another passkey sheet is open", details: nil))
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let text = arguments["options"] as? String,
            let data = text.data(using: .utf8),
            let options = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else {
        result(FlutterError(code: "failed", message: "no options", details: nil))
        return
      }
      let ceremony = PasskeyCeremony(create: call.method == "create", anchor: anchor) { [weak self] outcome in
        self?.pending = nil
        result(outcome)
      }
      do {
        pending = ceremony
        try ceremony.start(options)
      } catch {
        pending = nil
        result(FlutterError(code: "failed", message: "\(error)", details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// One making or use of a passkey: the system's sheet, and its answer.
@available(iOS 16.0, *)
private final class PasskeyCeremony: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding {
  private let create: Bool
  private let anchor: () -> UIWindow?
  private let done: (Any?) -> Void
  private var controller: ASAuthorizationController?
  private var finished = false

  init(create: Bool, anchor: @escaping () -> UIWindow?, done: @escaping (Any?) -> Void) {
    self.create = create
    self.anchor = anchor
    self.done = done
    super.init()
  }

  /// Shows the system's sheet for [options]. Throws where they lack what a
  /// passkey needs.
  func start(_ options: [String: Any]) throws {
    let requests = try (create ? registrationRequests(options) : assertionRequests(options))
    let controller = ASAuthorizationController(authorizationRequests: requests)
    controller.delegate = self
    controller.presentationContextProvider = self
    self.controller = controller
    controller.performRequests()
  }

  /// A passkey of this phone (or of a phone nearby) and a security key, both
  /// offered: the person picks in the sheet.
  private func registrationRequests(_ options: [String: Any]) throws -> [ASAuthorizationRequest] {
    guard let rp = options["rp"] as? [String: Any], let rpId = rp["id"] as? String, !rpId.isEmpty else {
      throw OptionsError(missing: "rp")
    }
    guard let user = options["user"] as? [String: Any], let userId = bytesOf(user["id"]),
          let name = user["name"] as? String, !name.isEmpty
    else {
      throw OptionsError(missing: "user")
    }
    guard let challenge = bytesOf(options["challenge"]) else { throw OptionsError(missing: "challenge") }
    let given = user["displayName"] as? String ?? ""
    let displayName = given.isEmpty ? name : given
    let selection = options["authenticatorSelection"] as? [String: Any] ?? [:]
    let verification = userVerificationOf(selection["userVerification"])
    let exclude = descriptorsOf(options["excludeCredentials"])

    let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
      .createCredentialRegistrationRequest(challenge: challenge, name: name, userID: userId)
    platform.displayName = displayName
    platform.userVerificationPreference = verification
    platform.attestationPreference = ASAuthorizationPublicKeyCredentialAttestationKind.none
    // iOS 17.4 is the first to leave out the passkeys the account has.
    if #available(iOS 17.4, *) {
      platform.excludedCredentials = exclude.map {
        ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0.id)
      }
    }

    let key = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
      .createCredentialRegistrationRequest(challenge: challenge, displayName: displayName, name: name, userID: userId)
    key.credentialParameters = algorithmsOf(options["pubKeyCredParams"]).map {
      ASAuthorizationPublicKeyCredentialParameters(algorithm: ASCOSEAlgorithmIdentifier(rawValue: $0))
    }
    key.excludedCredentials = exclude.map {
      ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: $0.id, transports: $0.keyTransports)
    }
    key.residentKeyPreference = residentKeyOf(selection)
    key.userVerificationPreference = verification
    key.attestationPreference = ASAuthorizationPublicKeyCredentialAttestationKind.none
    return [platform, key]
  }

  /// The account's passkeys on this phone, a phone nearby or a security key.
  private func assertionRequests(_ options: [String: Any]) throws -> [ASAuthorizationRequest] {
    let given = options["rpId"] as? String ?? ""
    let rpId = given.isEmpty ? "zestssh.com" : given
    guard let challenge = bytesOf(options["challenge"]) else { throw OptionsError(missing: "challenge") }
    let verification = userVerificationOf(options["userVerification"])
    let allow = descriptorsOf(options["allowCredentials"])

    let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
      .createCredentialAssertionRequest(challenge: challenge)
    platform.allowedCredentials = allow.map {
      ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0.id)
    }
    platform.userVerificationPreference = verification

    let key = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
      .createCredentialAssertionRequest(challenge: challenge)
    key.allowedCredentials = allow.map {
      ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: $0.id, transports: $0.keyTransports)
    }
    key.userVerificationPreference = verification
    return [platform, key]
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    anchor() ?? ASPresentationAnchor()
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    // The SDK marks some of these Data, some Data? and some Data!: each is
    // read into a Data? first, which compiles whichever it is.
    let json: [String: Any]
    switch authorization.credential {
    case let made as ASAuthorizationPlatformPublicKeyCredentialRegistration:
      let object: Data? = made.rawAttestationObject
      guard let attestation = object else { return fail("failed", "no attestation object") }
      let attachment = attachmentOf(made)
      json = registrationJSON(
        id: made.credentialID,
        clientData: made.rawClientDataJSON,
        attestation: attestation,
        // As Safari says of them: a passkey of this phone is reached here and
        // from other devices by QR code; one made on a phone nearby, by QR
        // code only.
        transports: attachment == "cross-platform" ? ["hybrid"] : ["hybrid", "internal"],
        attachment: attachment,
        residentKey: true
      )
    case let made as ASAuthorizationSecurityKeyPublicKeyCredentialRegistration:
      let object: Data? = made.rawAttestationObject
      guard let attestation = object else { return fail("failed", "no attestation object") }
      json = registrationJSON(
        id: made.credentialID,
        clientData: made.rawClientDataJSON,
        attestation: attestation,
        transports: [],
        attachment: "cross-platform",
        residentKey: nil
      )
    case let used as ASAuthorizationPlatformPublicKeyCredentialAssertion:
      let authData: Data? = used.rawAuthenticatorData
      let signed: Data? = used.signature
      let handle: Data? = used.userID
      guard let authenticatorData = authData, let signature = signed else { return fail("failed", "no signature") }
      json = assertionJSON(
        id: used.credentialID,
        clientData: used.rawClientDataJSON,
        authenticatorData: authenticatorData,
        signature: signature,
        userHandle: handle,
        attachment: attachmentOf(used)
      )
    case let used as ASAuthorizationSecurityKeyPublicKeyCredentialAssertion:
      let authData: Data? = used.rawAuthenticatorData
      let signed: Data? = used.signature
      let handle: Data? = used.userID
      guard let authenticatorData = authData, let signature = signed else { return fail("failed", "no signature") }
      json = assertionJSON(
        id: used.credentialID,
        clientData: used.rawClientDataJSON,
        authenticatorData: authenticatorData,
        signature: signature,
        userHandle: handle,
        attachment: "cross-platform"
      )
    default:
      return fail("failed", "not a passkey")
    }
    guard JSONSerialization.isValidJSONObject(json),
          let data = try? JSONSerialization.data(withJSONObject: json),
          let text = String(data: data, encoding: .utf8)
    else {
      return fail("failed", "response not written")
    }
    finish(text)
  }

  func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
    finish(failureOf(error))
  }

  /// Where the passkey was: this phone's own, or another device's (iOS 16.6
  /// is the first to say; null before it).
  private func attachmentOf(_ made: ASAuthorizationPlatformPublicKeyCredentialRegistration) -> String? {
    if #available(iOS 16.6, *) {
      return made.attachment == .crossPlatform ? "cross-platform" : "platform"
    }
    return nil
  }

  private func attachmentOf(_ used: ASAuthorizationPlatformPublicKeyCredentialAssertion) -> String? {
    if #available(iOS 16.6, *) {
      return used.attachment == .crossPlatform ? "cross-platform" : "platform"
    }
    return nil
  }

  /// What the system's [error] means, as the Dart side's code: the person's
  /// cancel is "cancelled"; an app zestssh.com does not name is "security".
  private func failureOf(_ error: Error) -> FlutterError {
    let ns = error as NSError
    let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? ""
    let said = "\(ns.domain) \(ns.code): \(ns.localizedDescription) \(reason)"
      .trimmingCharacters(in: .whitespaces)
    guard ns.domain == ASAuthorizationError.errorDomain else {
      return FlutterError(code: "failed", message: said, details: nil)
    }
    switch ns.code {
    case ASAuthorizationError.Code.canceled.rawValue:
      return FlutterError(code: "cancelled", message: nil, details: nil)
    case 1005:
      // notInteractive: nothing to show without asking (no passkey here).
      return FlutterError(code: "no-credential", message: said, details: nil)
    case 1006:
      // matchedExcludedCredential (iOS 18): this device holds one of the
      // account's passkeys already.
      return FlutterError(code: "invalid-state", message: said, details: nil)
    default:
      if said.contains("not associated") {
        // The app is not in zestssh.com's apple-app-site-association, or
        // the entitlement is missing from this build.
        return FlutterError(code: "security", message: said, details: nil)
      }
      return FlutterError(code: "failed", message: said, details: nil)
    }
  }

  private func fail(_ code: String, _ message: String) {
    finish(FlutterError(code: code, message: message, details: nil))
  }

  /// Answers the Dart side, once.
  private func finish(_ outcome: Any?) {
    guard !finished else { return }
    finished = true
    controller = nil
    done(outcome)
  }
}

/// What the options lacked.
private struct OptionsError: Error, CustomStringConvertible {
  let missing: String
  var description: String { "options: no \(missing)" }
}

/// A passkey of the account, as the options list it.
private struct Descriptor {
  let id: Data
  let transports: [String]

  /// The ways a security key is reached, of those named; all of them where
  /// none is (a passkey's own transports say nothing of a key).
  @available(macOS 13.0, iOS 16.0, *)
  var keyTransports: [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport] {
    var out: [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport] = []
    for transport in transports {
      switch transport {
      case "usb": out.append(.usb)
      case "nfc": out.append(.nfc)
      case "ble": out.append(.bluetooth)
      default: break
      }
    }
    return out.isEmpty ? [.usb, .nfc, .bluetooth] : out
  }
}

/// [value] as bytes where it is base64url (padded or not); nil otherwise.
private func bytesOf(_ value: Any?) -> Data? {
  guard let text = value as? String, !text.isEmpty else { return nil }
  var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  standard = standard.replacingOccurrences(of: "=", with: "")
  let rest = standard.count % 4
  if rest == 1 { return nil }
  if rest > 0 { standard += String(repeating: "=", count: 4 - rest) }
  return Data(base64Encoded: standard)
}

/// [data] as base64url without padding.
private func b64u(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

private func descriptorsOf(_ value: Any?) -> [Descriptor] {
  guard let list = value as? [[String: Any]] else { return [] }
  return list.compactMap { item in
    guard (item["type"] as? String ?? "public-key") == "public-key", let id = bytesOf(item["id"]) else { return nil }
    return Descriptor(id: id, transports: item["transports"] as? [String] ?? [])
  }
}

/// The COSE algorithms of the options, each once; ES256 and RS256 where
/// none is named.
private func algorithmsOf(_ value: Any?) -> [Int] {
  var out: [Int] = []
  for item in value as? [[String: Any]] ?? [] {
    guard (item["type"] as? String ?? "public-key") == "public-key", let alg = item["alg"] as? Int else { continue }
    if !out.contains(alg) { out.append(alg) }
  }
  return out.isEmpty ? [-7, -257] : out
}

// These two and keyTransports above name types the system has only from
// macOS 12 and iOS 15, and the Mac app is built for macOS 11: without the
// mark the Mac build stops here. Everything that calls them is the
// ceremony, which carries the same mark.
@available(macOS 13.0, iOS 16.0, *)
private func userVerificationOf(_ value: Any?) -> ASAuthorizationPublicKeyCredentialUserVerificationPreference {
  switch value as? String {
  case "required": return .required
  case "discouraged": return .discouraged
  default: return .preferred
  }
}

/// residentKey as WebAuthn reads it, and requireResidentKey where only that
/// was sent.
@available(macOS 13.0, iOS 16.0, *)
private func residentKeyOf(_ selection: [String: Any]) -> ASAuthorizationPublicKeyCredentialResidentKeyPreference {
  let required = selection["requireResidentKey"] as? Bool ?? false
  switch selection["residentKey"] as? String ?? (required ? "required" : "discouraged") {
  case "required": return .required
  case "preferred": return .preferred
  default: return .discouraged
  }
}

private func registrationJSON(
  id: Data, clientData: Data, attestation: Data, transports: [String], attachment: String?, residentKey: Bool?
) -> [String: Any] {
  var extensions: [String: Any] = [:]
  if let residentKey = residentKey { extensions["credProps"] = ["rk": residentKey] }
  var json: [String: Any] = [
    "id": b64u(id),
    "rawId": b64u(id),
    "type": "public-key",
    "response": [
      "clientDataJSON": b64u(clientData),
      "attestationObject": b64u(attestation),
      "transports": transports,
    ] as [String: Any],
    "clientExtensionResults": extensions,
  ]
  if let attachment = attachment { json["authenticatorAttachment"] = attachment }
  return json
}

private func assertionJSON(
  id: Data, clientData: Data, authenticatorData: Data, signature: Data, userHandle: Data?, attachment: String?
) -> [String: Any] {
  var response: [String: Any] = [
    "clientDataJSON": b64u(clientData),
    "authenticatorData": b64u(authenticatorData),
    "signature": b64u(signature),
  ]
  if let handle = userHandle, !handle.isEmpty { response["userHandle"] = b64u(handle) }
  var json: [String: Any] = [
    "id": b64u(id),
    "rawId": b64u(id),
    "type": "public-key",
    "response": response,
    "clientExtensionResults": [String: Any](),
  ]
  if let attachment = attachment { json["authenticatorAttachment"] = attachment }
  return json
}
