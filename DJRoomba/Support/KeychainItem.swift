import Foundation
import Security

/// A single secret stored in the macOS Keychain as a generic-password item.
///
/// Used for the OpenAI API key: a credential, not a preference, so it belongs
/// in the Keychain rather than `UserDefaults` (where it would sit in plaintext
/// in a plist and ride along in backups). A sandboxed app is automatically
/// granted a keychain access group keyed to its application-identifier, so no
/// `keychain-access-groups` entitlement is required.
///
/// A small `Sendable` value (`service` + `account`); the actual I/O is the
/// three `SecItem*` calls. Errors surface as `KeychainItem.Error` carrying the
/// raw `OSStatus` for diagnostics.
struct KeychainItem: Sendable {

  // MARK: Internal

  enum Error: Swift.Error, CustomStringConvertible {
    /// A `SecItem*` call returned an unexpected, non-success status.
    case unexpectedStatus(OSStatus)
    /// The stored data was not valid UTF-8 (corrupt / written by something else).
    case dataNotUTF8

    var description: String {
      switch self {
      case .unexpectedStatus(let status):
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain error \(status): \(message)"

      case .dataNotUTF8:
        return "the stored Keychain value was not valid UTF-8"
      }
    }
  }

  let service: String
  let account: String

  /// The stored secret, or `nil` if no item exists.
  func read() throws -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else { return nil }
      guard let value = String(data: data, encoding: .utf8) else { throw Error.dataNotUTF8 }
      return value

    case errSecItemNotFound:
      return nil

    default:
      throw Error.unexpectedStatus(status)
    }
  }

  /// Create or overwrite the secret. Stored `WhenUnlocked` — the app only
  /// reads it while the user is actively driving it.
  func save(_ value: String) throws {
    let data = Data(value.utf8)
    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      [kSecValueData as String: data] as CFDictionary,
    )
    switch updateStatus {
    case errSecSuccess:
      return

    case errSecItemNotFound:
      var addQuery = baseQuery
      addQuery[kSecValueData as String] = data
      addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
      let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw Error.unexpectedStatus(addStatus) }

    default:
      throw Error.unexpectedStatus(updateStatus)
    }
  }

  /// Remove the secret. A no-op (not an error) if nothing is stored.
  func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Error.unexpectedStatus(status)
    }
  }

  // MARK: Private

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
