import FlutterMacOS
import Foundation
import Security

/// The names of the app's keychain items (lib/services/profiles/mac_keychain.dart).
///
/// The app uses the legacy keychain: it carries no keychain access group (it was
/// signed ad hoc until 3.4.0, and its Developer ID signature since names none).
/// There the plugin's readAll, a query with kSecMatchLimitAll and kSecReturnData,
/// fails with errSecParam (-50). The same query for the items' attributes alone
/// works, so the app lists the names here and reads each one through the plugin.
///
/// The query is the one flutter_secure_storage_macos 3.1.3 writes items with
/// (baseQuery in FlutterSecureStorage.swift), so it finds what the plugin keeps.
enum KeychainNames {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "zestssh/keychain_names", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "names" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let arguments = call.arguments as? [String: Any]
      result(names(options: arguments?["options"] as? [String: Any] ?? [:]))
    }
  }

  private static func names(options: [String: Any]) -> Any {
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrAccessible: accessible(options["accessibility"] as? String),
      kSecAttrSynchronizable: (options["synchronizable"] as? String) == "true",
      kSecMatchLimit: kSecMatchLimitAll,
      kSecReturnAttributes: true,
    ]
    if #available(macOS 10.15, *) {
      // Absent means true, as in the plugin's own parsing of its options.
      query[kSecUseDataProtectionKeychain] = (options["useDataProtectionKeyChain"] as? String).map { $0 == "true" } ?? true
    }
    if let service = options["accountName"] as? String {
      query[kSecAttrService] = service
    }
    if let group = options["groupId"] as? String {
      query[kSecAttrAccessGroup] = group
    }

    var found: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &found)
    if status == errSecItemNotFound {
      return [String]()
    }
    guard status == errSecSuccess else {
      let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown"
      return FlutterError(code: "keychain", message: "Code: \(status), Message: \(message)", details: status)
    }
    let items = found as? [[String: Any]] ?? []
    return items.compactMap { $0[kSecAttrAccount as String] as? String }
  }

  /// As the plugin's parseAccessibleAttr.
  private static func accessible(_ name: String?) -> CFString {
    switch name {
    case "passcode":
      return kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
    case "unlocked_this_device":
      return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    case "first_unlock":
      return kSecAttrAccessibleAfterFirstUnlock
    case "first_unlock_this_device":
      return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    default:
      return kSecAttrAccessibleWhenUnlocked
    }
  }
}
