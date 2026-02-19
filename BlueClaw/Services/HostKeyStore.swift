import Foundation
import Security

/// TOFU (Trust On First Use) SSH host key fingerprint storage.
/// Stores SHA-256 fingerprints keyed by hostname.
nonisolated enum HostKeyStore {
    private static let keychainService = "priceconsulting.BlueClaw.hostkeys"

    /// Save a host key fingerprint for a hostname.
    static func save(fingerprint: String, for hostname: String) {
        let data = Data(fingerprint.utf8)
        let account = sanitize(hostname)

        // Delete existing entry
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Retrieve the stored fingerprint for a hostname, or nil if not seen before.
    static func retrieve(for hostname: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: sanitize(hostname),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a stored fingerprint.
    static func delete(for hostname: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: sanitize(hostname),
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func sanitize(_ hostname: String) -> String {
        hostname
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }
}
