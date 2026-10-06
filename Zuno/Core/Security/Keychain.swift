import Foundation
import Security

/// Minimal Keychain wrapper for small sensitive local values (never tokens in UserDefaults).
/// Supabase session tokens are stored by the SDK's own Keychain storage.
struct Keychain: Sendable {
    let service: String

    static let standard = Keychain(service: "lk.zuno.app.secure")

    enum KeychainError: Error, Equatable { case unexpectedStatus(OSStatus) }

    func set(_ data: Data, for key: String) throws {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { $1 }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func data(for key: String) -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func remove(_ key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    func removeAll() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }

    func bool(for key: String) -> Bool { data(for: key) == Data([1]) }
    func set(_ value: Bool, for key: String) { try? set(Data([value ? 1 : 0]), for: key) }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
