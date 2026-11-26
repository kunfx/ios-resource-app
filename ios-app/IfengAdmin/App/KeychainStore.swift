import Foundation
import Security

/// 认证凭据只保存在 Keychain；按服务器 host 分账号，换服务器不会串号。
enum KeychainStore {
    static func save(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfig.keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Keychain 里保存的会话记录。
struct StoredSession: Codable {
    var credentials: Credentials
    var accountId: Int
    var profileName: String?
    var profileEmail: String?

    static func load(host: String) -> StoredSession? {
        guard let data = KeychainStore.load(account: host) else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    func save(host: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        _ = KeychainStore.save(data, account: host)
    }

    static func remove(host: String) {
        KeychainStore.delete(account: host)
    }
}
