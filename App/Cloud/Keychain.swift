import Foundation
import Security

enum KeychainError: Error, Sendable, Equatable, CustomStringConvertible {
    case unhandled(status: OSStatus)
    case invalidData

    var description: String {
        switch self {
        case .unhandled(let status):
            let message = SecCopyErrorMessageString(status, nil).map { String($0 as NSString) } ?? "unknown"
            return "keychain error \(status) (\(message))"
        case .invalidData:
            return "keychain item was not valid UTF-8"
        }
    }
}

/// Thin `SecItem` wrapper for the few secrets the app keeps: the backend bearer token and the
/// device identity.
///
/// Items are generic passwords under one service, accessible after the first unlock (the app
/// refreshes tokens in the background), and never synchronised to iCloud — a token is bound to
/// one device row on the backend.
enum Keychain {
    static let service = "tech.alandiza.roommapper"

    /// Well-known accounts. Values are opaque to the rest of the app.
    enum Account: String, Sendable {
        /// JSON blob with the backend token, its expiry and the signed-in user.
        case credentials = "backend.credentials"
        /// This installation's device UUID, reported to `POST /v1/auth/google`.
        case deviceIdentity = "device.identity"
    }

    static func setData(_ data: Data, for account: Account) throws(KeychainError) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw .unhandled(status: addStatus) }
        default:
            throw .unhandled(status: updateStatus)
        }
    }

    /// The stored bytes, or `nil` when the account has no item.
    static func data(for account: Account) throws(KeychainError) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw .unhandled(status: status)
        }
    }

    static func setString(_ string: String, for account: Account) throws(KeychainError) {
        try setData(Data(string.utf8), for: account)
    }

    static func string(for account: Account) throws(KeychainError) -> String? {
        guard let data = try data(for: account) else { return nil }
        guard let string = String(data: data, encoding: .utf8) else { throw .invalidData }
        return string
    }

    /// Removes the item. Missing items are not an error.
    static func remove(_ account: Account) throws(KeychainError) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .unhandled(status: status) }
    }

    // MARK: - Codable helpers

    static func setValue(_ value: some Encodable, for account: Account) throws {
        try setData(try JSONEncoder().encode(value), for: account)
    }

    static func value<T: Decodable>(_ type: T.Type, for account: Account) throws -> T? {
        guard let data = try data(for: account) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
