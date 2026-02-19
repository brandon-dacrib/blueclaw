import Foundation
import Crypto
import Security

nonisolated enum SSHKeyManager {
    private static let keychainService = "priceconsulting.BlueClaw"
    private static let keychainAccount = "ssh-private-key"

    // MARK: - Key Generation

    /// Generate a new Ed25519 key pair, store the private key in Keychain, and return it.
    @discardableResult
    static func generateAndStore() -> Curve25519.Signing.PrivateKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let data = privateKey.rawRepresentation

        // Delete any existing key first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(attributes as CFDictionary, nil)

        return privateKey
    }

    // MARK: - Key Retrieval

    /// Retrieve the stored Ed25519 private key, or nil if none exists.
    static func retrievePrivateKey() -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    /// Whether an SSH key exists in the Keychain.
    static var hasKey: Bool {
        retrievePrivateKey() != nil
    }

    // MARK: - Public Key Formatting

    /// Get the public key in OpenSSH `authorized_keys` format.
    /// Returns `ssh-ed25519 AAAA...base64... BlueClaw-iOS`
    static func publicKeyOpenSSH() -> String? {
        guard let privateKey = retrievePrivateKey() else { return nil }
        return formatPublicKey(privateKey.publicKey)
    }

    /// Format a public key in OpenSSH wire format.
    static func formatPublicKey(_ publicKey: Curve25519.Signing.PublicKey) -> String {
        let keyType = "ssh-ed25519"
        let keyTypeBytes = Array(keyType.utf8)
        let pubKeyBytes = Array(publicKey.rawRepresentation)

        // OpenSSH wire format: uint32 len + "ssh-ed25519" + uint32 len + 32-byte pubkey
        var wireFormat = Data()

        var keyTypeLen = UInt32(keyTypeBytes.count).bigEndian
        wireFormat.append(Data(bytes: &keyTypeLen, count: 4))
        wireFormat.append(Data(keyTypeBytes))

        var pubKeyLen = UInt32(pubKeyBytes.count).bigEndian
        wireFormat.append(Data(bytes: &pubKeyLen, count: 4))
        wireFormat.append(Data(pubKeyBytes))

        let base64 = wireFormat.base64EncodedString()
        return "\(keyType) \(base64) BlueClaw-iOS"
    }

    // MARK: - Device Identity

    /// Get the raw 32-byte public key as base64url (for gateway device identity).
    static func publicKeyBase64URL() -> String? {
        guard let privateKey = retrievePrivateKey() else { return nil }
        return base64URLEncode(Data(privateKey.publicKey.rawRepresentation))
    }

    /// Derive the device ID: SHA-256 of the raw public key bytes, hex-encoded.
    static func deviceId() -> String? {
        guard let privateKey = retrievePrivateKey() else { return nil }
        let hash = SHA256.hash(data: privateKey.publicKey.rawRepresentation)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Build and sign a device identity for the gateway connect handshake.
    static func buildDeviceIdentity(token: String, nonce: String?) -> DeviceInfo? {
        guard let privateKey = retrievePrivateKey(),
              let deviceId = deviceId(),
              let publicKeyB64 = publicKeyBase64URL() else { return nil }

        let signedAt = Int(Date().timeIntervalSince1970 * 1000)
        let clientId = "openclaw-ios"
        let clientMode = "node"
        let role = "operator"
        let scopes = "operator.admin"

        // Build payload matching gateway's buildDeviceAuthPayload
        let version = nonce != nil ? "v2" : "v1"
        var parts = [version, deviceId, clientId, clientMode, role, scopes, String(signedAt), token]
        if version == "v2" {
            parts.append(nonce ?? "")
        }
        let payload = parts.joined(separator: "|")

        guard let payloadData = payload.data(using: .utf8),
              let signature = try? privateKey.signature(for: payloadData) else {
            return nil
        }

        return DeviceInfo(
            id: deviceId,
            publicKey: publicKeyB64,
            signature: base64URLEncode(Data(signature)),
            signedAt: signedAt,
            nonce: nonce
        )
    }

    // MARK: - Base64URL Helpers

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Key Deletion

    /// Delete the stored SSH key from Keychain.
    static func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
