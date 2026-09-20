import Foundation
import Security

/// Stores the Model Studio credentials in the login keychain.
///
/// The CLI read these from `.env`, which a bundled app cannot do: it has no
/// project directory to walk up from, and shipping a file with the key beside
/// the binary defeats the point. The keychain also survives reinstalls and
/// keeps the key out of any backup of the app's container.
///
/// The environment is still consulted first so a debug run from Xcode can
/// override the stored value with a scheme variable.
nonisolated struct CredentialStore {
    struct Credentials: Sendable, Equatable {
        var apiKey: String
        var workspaceID: String

        var isComplete: Bool { !apiKey.isEmpty && !workspaceID.isEmpty }
    }

    /// One keychain item holds both fields; they are useless apart.
    ///
    /// Spelled with the original bundle identifier rather than the current
    /// product name: renaming it would strand the credentials already stored
    /// under the old service, forcing everyone to re-enter their key.
    private static let service = "com.ikuyu.livetranslate-bridge.dashscope"
    private static let account = "default"

    static func load() -> Credentials {
        if let fromEnvironment = environmentCredentials() { return fromEnvironment }

        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let decoded = try? JSONDecoder().decode(Stored.self, from: data)
        else {
            return Credentials(apiKey: "", workspaceID: "")
        }
        return Credentials(apiKey: decoded.apiKey, workspaceID: decoded.workspaceID)
    }

    @discardableResult
    static func save(_ credentials: Credentials) -> Bool {
        guard let data = try? JSONEncoder().encode(
            Stored(apiKey: credentials.apiKey, workspaceID: credentials.workspaceID)
        ) else { return false }

        // Update in place when an item already exists; SecItemAdd would fail
        // with errSecDuplicateItem.
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var insert = baseQuery()
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func clear() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func environmentCredentials() -> Credentials? {
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["DASHSCOPE_API_KEY"], !apiKey.isEmpty,
              let workspaceID = environment["DASHSCOPE_WORKSPACE_ID"],
              !workspaceID.isEmpty else { return nil }
        return Credentials(apiKey: apiKey, workspaceID: workspaceID)
    }

    private struct Stored: Codable {
        let apiKey: String
        let workspaceID: String
    }
}
