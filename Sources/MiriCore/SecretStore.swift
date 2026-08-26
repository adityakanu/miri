import Foundation
import Security

/// Keychain-backed storage for provider API keys.
///
/// Miri launches from Finder as a GUI app, which does not inherit the login
/// shell's environment, so an exported API key is invisible to it. The Keychain
/// is the only place a key can live that works for both launch paths, and it
/// keeps the secret out of `config.toml`.
public enum SecretStore {
    public static let defaultAccount = "cloud-stt"
    private static let service = "dev.miri.speech"

    public static func save(_ secret: String, account: String = defaultAccount) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { try remove(account: account); return }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }

    public static func read(account: String = defaultAccount) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func remove(account: String = defaultAccount) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
    }

    public static func hasSecret(account: String = defaultAccount) -> Bool { read(account: account) != nil }
}

public struct SecretStoreError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "Keychain access failed: \(detail)"
    }
}
