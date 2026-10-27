import Foundation
import Security

struct GatewayCredential: Codable {
    let endpoint: String
    let key: String
}

struct KeychainStore {
    private let service = "MagpiePocket.gateway"
    private let account = "active-endpoint"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> GatewayCredential? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialError.unavailable
        }
        do { return try JSONDecoder().decode(GatewayCredential.self, from: data) }
        catch { throw CredentialError.unavailable }
    }

    func save(_ credential: GatewayCredential) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(credential),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let newItem = query.merging(attributes) { _, new in new }
            guard SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess else {
                throw CredentialError.unavailable
            }
        } else if status != errSecSuccess {
            throw CredentialError.unavailable
        }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.unavailable
        }
    }
}

enum CredentialError: LocalizedError {
    case unavailable, missing, endpointChanged, invalidKey

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Keychain is unavailable. Unlock the device and try again."
        case .missing: return "Add an HTTPS gateway and its gateway key in Settings first."
        case .endpointChanged: return "A different gateway requires its own key. Enter the key again."
        case .invalidKey: return "The gateway key must not contain whitespace or control characters."
        }
    }
}
