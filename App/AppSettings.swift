import Combine
import Foundation
import MagpieCore

@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var baseURL: String
    @Published private(set) var hasKey = false
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let keychain = KeychainStore()
    private let endpointPreference = "gateway.baseURL"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        baseURL = defaults.string(forKey: endpointPreference) ?? ""
        refreshKeyStatus()
    }

    func configuration() throws -> GatewayConfiguration {
        let normalized = try GatewayClient.validatedBaseURL(baseURL).absoluteString
        guard let credential = try keychain.load(), !credential.key.isEmpty else {
            throw CredentialError.missing
        }
        // Bind credentials to the full endpoint, not just the host.
        guard credential.endpoint == normalized else { throw CredentialError.endpointChanged }
        return GatewayConfiguration(baseURL: normalized, apiKey: credential.key)
    }

    func save(baseURL: String, apiKey: String) throws {
        let normalized = try GatewayClient.validatedBaseURL(baseURL).absoluteString
        let key: String
        if apiKey.isEmpty {
            guard let saved = try keychain.load(), saved.endpoint == normalized else {
                throw CredentialError.endpointChanged
            }
            key = saved.key
        } else {
            guard apiKey.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
                throw CredentialError.invalidKey
            }
            key = apiKey
        }
        try keychain.save(GatewayCredential(endpoint: normalized, key: key))
        defaults.set(normalized, forKey: endpointPreference)
        self.baseURL = normalized
        hasKey = true
        errorMessage = nil
    }

    func removeKey() throws {
        try keychain.remove()
        hasKey = false
        errorMessage = nil
    }

    private func refreshKeyStatus() {
        do {
            let credential = try keychain.load()
            hasKey = credential?.endpoint == baseURL && !(credential?.key.isEmpty ?? true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
