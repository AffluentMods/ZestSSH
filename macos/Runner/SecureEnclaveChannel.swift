import CryptoKit
import FlutterMacOS
import Foundation

/// The Mac's Secure Enclave for the vault's hardware layer (4.0), on the
/// channel zestssh/secure_enclave
/// (lib/services/mac_secure_enclave_vault_service.dart), as the TPM is on
/// Windows (lib/services/windows_tpm_vault_service.dart): the app makes a
/// random 256-bit key, has it sealed here to a key that was made in the
/// enclave and cannot leave it, and keeps only what comes back. Copied to
/// another Mac, those bytes open nothing.
///
/// Sealing: a P-256 key agreement key is made in the enclave; a second,
/// ordinary P-256 key is made for this one sealing and thrown away after it.
/// The two agree on a secret, HKDF-SHA256 makes an AES-256 key of it (bound
/// to both public keys and a label), and AES-GCM seals the vault's key under
/// that. Kept: the enclave key as the enclave hands it out (bytes only this
/// enclave can use), the one-time key's public half, and the sealed box.
/// Opening asks the enclave for the same secret again; nothing else can.
///
/// No Touch ID question: the enclave key is usable while the Mac is unlocked,
/// as the TPM key is, and the vault's PIN is asked by the app as before.
/// CryptoKit's enclave needs no entitlement and no signature (tried in an
/// unsigned program on an M1 Mac mini, 14 November 2026), so every build has
/// it on a Mac with Apple silicon or a T2 chip; an older Intel Mac has none,
/// and says so.
enum SecureEnclaveChannel {
  static let name = "zestssh/secure_enclave"

  /// What the HKDF is told this key is for, with both public keys after it.
  private static let label = Data("ZestSSH vault hardware key v1".utf8)

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isAvailable":
        result(usable)
      case "seal":
        guard let arguments = call.arguments as? [String: Any],
              let key = (arguments["key"] as? FlutterStandardTypedData)?.data, key.count == 32
        else {
          result(FlutterError(code: "failed", message: "no 32-byte key to seal", details: nil))
          return
        }
        do {
          result(try seal(key))
        } catch {
          result(FlutterError(code: "failed", message: "seal: \(error)", details: nil))
        }
      case "open":
        guard let arguments = call.arguments as? [String: Any],
              let enclaveKey = (arguments["enclaveKey"] as? FlutterStandardTypedData)?.data,
              let oneTime = (arguments["oneTimeKey"] as? FlutterStandardTypedData)?.data,
              let sealed = (arguments["sealed"] as? FlutterStandardTypedData)?.data
        else {
          result(FlutterError(code: "failed", message: "nothing to open", details: nil))
          return
        }
        do {
          result(FlutterStandardTypedData(bytes: try open(enclaveKey: enclaveKey, oneTime: oneTime, sealed: sealed)))
        } catch {
          // Another Mac's enclave, or bytes that were changed: either way
          // this enclave cannot open them.
          result(FlutterError(code: "not-this-mac", message: "open: \(error)", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Whether this Mac has an enclave that makes a key for this app: asked
  /// once in a run, by making one (it is not kept).
  private static let usable: Bool = {
    guard SecureEnclave.isAvailable else { return false }
    return (try? SecureEnclave.P256.KeyAgreement.PrivateKey()) != nil
  }()

  private static func seal(_ key: Data) throws -> [String: Any] {
    let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
    let oneTime = P256.KeyAgreement.PrivateKey()
    let secret = try oneTime.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey)
    let wrapping = wrappingKey(secret, enclave: enclaveKey.publicKey, oneTime: oneTime.publicKey)
    guard let sealed = try AES.GCM.seal(key, using: wrapping).combined else {
      throw SealError.noBox
    }
    return [
      "enclaveKey": FlutterStandardTypedData(bytes: enclaveKey.dataRepresentation),
      "oneTimeKey": FlutterStandardTypedData(bytes: oneTime.publicKey.x963Representation),
      "sealed": FlutterStandardTypedData(bytes: sealed),
    ]
  }

  private static func open(enclaveKey: Data, oneTime: Data, sealed: Data) throws -> Data {
    let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: enclaveKey)
    let oneTimeKey = try P256.KeyAgreement.PublicKey(x963Representation: oneTime)
    let secret = try key.sharedSecretFromKeyAgreement(with: oneTimeKey)
    let wrapping = wrappingKey(secret, enclave: key.publicKey, oneTime: oneTimeKey)
    return try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed), using: wrapping)
  }

  private static func wrappingKey(
    _ secret: SharedSecret,
    enclave: P256.KeyAgreement.PublicKey,
    oneTime: P256.KeyAgreement.PublicKey
  ) -> SymmetricKey {
    secret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: Data(),
      sharedInfo: label + enclave.x963Representation + oneTime.x963Representation,
      outputByteCount: 32)
  }

  private enum SealError: Error {
    case noBox
  }
}
