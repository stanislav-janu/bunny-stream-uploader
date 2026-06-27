import Foundation
import Security

/// Bunny Stream credentials held securely in the login keychain.
struct Credentials: Equatable {
    var apiKey: String
    var libraryId: String

    var isComplete: Bool {
        return !apiKey.isEmpty && !libraryId.isEmpty
    }
}

/// Stores and reads Bunny credentials in the keychain. Both values live in ONE item
/// (one keychain access = one possible authorization prompt).
/// The API key is never logged or shown after entry.
enum KeychainStore {
    private static let service = "net.bunnyuploader.BunnyUploader"
    private static let account = "bunny-credentials"

    static func load() -> Credentials {
        guard let data = read(),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            return Credentials(apiKey: "", libraryId: "")
        }
        return Credentials(apiKey: object["apiKey"] ?? "", libraryId: object["libraryId"] ?? "")
    }

    static func save(_ credentials: Credentials) {
        let dict = ["apiKey": credentials.apiKey, "libraryId": credentials.libraryId]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        write(data)
    }

    static func clear() {
        delete()
    }

    // MARK: - Low-level operations (single item)

    private static func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ data: Data) {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
