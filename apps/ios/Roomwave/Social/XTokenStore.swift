import Foundation
import Security

struct XOAuthTokens: Codable, Sendable {
    let clientID: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
}

enum XTokenStore {
    private static let service = "org.timelabs.moleculefoundry.x.oauth"
    private static let account = "native-user"

    static func read() throws -> XOAuthTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw XActivityError.storage }
        return try JSONDecoder().decode(XOAuthTokens.self, from: data)
    }

    static func save(_ tokens: XOAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let update: [String: Any] = [kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            for (key, value) in update { item[key] = value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw XActivityError.storage }
        } else if status != errSecSuccess { throw XActivityError.storage }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw XActivityError.storage }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
