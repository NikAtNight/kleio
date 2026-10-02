import Foundation
import Security

protocol SummaryCredentialStore {
    func apiKey(for provider: SummaryService.Provider) throws -> String?
    func saveAPIKey(_ key: String, for provider: SummaryService.Provider) throws
}

/// Cloud credentials stay in the login Keychain, with one account per vendor.
struct KeychainSummaryCredentialStore: SummaryCredentialStore {
    private let service = "app.talix.scribe.summary"

    func apiKey(for provider: SummaryService.Provider) throws -> String? {
        guard provider.usesAPIKey else { return nil }
        var query = query(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StorageError.status(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw StorageError.invalidData
        }
        return key
    }

    func saveAPIKey(_ key: String, for provider: SummaryService.Provider) throws {
        guard provider.usesAPIKey else { return }
        let query = query(for: provider)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw StorageError.status(status)
            }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, value in value }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError.status(status) }
    }

    private func query(for provider: SummaryService.Provider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue,
         kSecAttrSynchronizable as String: false]
    }

    enum StorageError: LocalizedError {
        case status(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .status(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
                return "Couldn't access the API key in Keychain. \(detail) Retry in Settings → AI Summaries."
            case .invalidData:
                return "The API key in Keychain couldn't be read. Save the key again in Settings → AI Summaries."
            }
        }
    }
}

/// Shared by Settings and generation. Tests inject a private preference suite
/// and credential store so they never use the user's defaults or Keychain.
struct SummarySettings {
    let defaults: UserDefaults
    let credentials: any SummaryCredentialStore

    init(defaults: UserDefaults = .standard,
         credentials: any SummaryCredentialStore = KeychainSummaryCredentialStore()) {
        self.defaults = defaults
        self.credentials = credentials
    }

    var provider: SummaryService.Provider {
        SummaryService.Provider(rawValue: defaults.string(forKey: "aiProvider") ?? "") ?? .anthropic
    }

    var prompt: String {
        let stored = defaults.string(forKey: "summaryPrompt") ?? ""
        return stored.isEmpty ? SummaryService.defaultPrompt : stored
    }

    func model(for provider: SummaryService.Provider) -> String {
        migrateLegacyModel()
        let stored = defaults.string(forKey: provider.modelDefaultsKey) ?? ""
        return stored.isEmpty ? provider.defaultModel : stored
    }

    func apiKey(for provider: SummaryService.Provider) throws -> String {
        guard provider.usesAPIKey else { return "" }
        migrateLegacyModel()
        if legacyProvider == provider { try migrateLegacyKey(to: provider) }
        return try credentials.apiKey(for: provider) ?? ""
    }

    func saveAPIKey(_ key: String, for provider: SummaryService.Provider) throws {
        guard provider.usesAPIKey else { return }
        // Capture ownership before a save can change or remove legacy settings.
        let owner = legacyProvider
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try credentials.saveAPIKey(trimmed, for: provider)
        // A deliberate replacement also completes migration for this vendor.
        if owner == provider { defaults.removeObject(forKey: "aiAPIKey") }
    }

    func migrateLegacySettings() throws {
        migrateLegacyModel()
        guard !(defaults.string(forKey: "aiAPIKey") ?? "").isEmpty else { return }
        guard let owner = legacyProvider else { throw MigrationError.unknownProvider }
        try migrateLegacyKey(to: owner)
    }

    var needsLegacyProvider: Bool {
        !(defaults.string(forKey: "aiAPIKey") ?? "").isEmpty && legacyProvider == nil
    }

    func assignLegacySettings(to provider: SummaryService.Provider) throws {
        guard provider.usesAPIKey, needsLegacyProvider else { return }
        defaults.set(provider.rawValue, forKey: "aiLegacyProvider")
        try migrateLegacySettings()
    }

    func captureLegacyProvider() {
        _ = legacyProvider
    }

    private var legacyProvider: SummaryService.Provider? {
        guard defaults.object(forKey: "aiAPIKey") != nil || defaults.object(forKey: "aiModel") != nil else {
            return nil
        }
        if defaults.string(forKey: "aiLegacyProvider") == nil {
            let raw = defaults.string(forKey: "aiProvider")
            // Missing provider historically meant Anthropic. An invalid or
            // local selection gives no evidence about the old cloud key.
            let selected: SummaryService.Provider?
            if let raw { selected = SummaryService.Provider(rawValue: raw) }
            else { selected = .anthropic }
            let owner = selected.flatMap { $0.usesAPIKey ? $0.rawValue : nil } ?? "unassigned"
            defaults.set(owner, forKey: "aiLegacyProvider")
        }
        guard let raw = defaults.string(forKey: "aiLegacyProvider"),
              let owner = SummaryService.Provider(rawValue: raw), owner.usesAPIKey else { return nil }
        return owner
    }

    private func migrateLegacyModel() {
        guard let owner = legacyProvider, let stored = defaults.string(forKey: "aiModel") else { return }
        if defaults.object(forKey: owner.modelDefaultsKey) == nil {
            defaults.set(stored, forKey: owner.modelDefaultsKey)
        }
        defaults.removeObject(forKey: "aiModel")
    }

    private func migrateLegacyKey(to owner: SummaryService.Provider) throws {
        guard let legacyKey = defaults.string(forKey: "aiAPIKey") else { return }
        if legacyKey.isEmpty {
            defaults.removeObject(forKey: "aiAPIKey")
            return
        }
        if (try credentials.apiKey(for: owner) ?? "").isEmpty {
            try credentials.saveAPIKey(legacyKey, for: owner)
        }
        // Never remove the plaintext copy after a failed Keychain operation.
        defaults.removeObject(forKey: "aiAPIKey")
    }

    func configuration() throws -> Configuration {
        let selected = provider
        return Configuration(provider: selected, model: model(for: selected),
                             apiKey: try apiKey(for: selected), prompt: prompt)
    }

    struct Configuration {
        let provider: SummaryService.Provider
        let model: String
        let apiKey: String
        let prompt: String

        var isConfigured: Bool {
            switch provider {
            case .anthropic, .openai: return !apiKey.isEmpty
            case .appleIntelligence: return true
            case .ollama: return !model.isEmpty
            case .claudeCode, .codex, .cursor: return provider.subscriptionCLI?.executableURL() != nil
            }
        }
    }

    enum MigrationError: LocalizedError {
        case unknownProvider

        var errorDescription: String? {
            "An older API key has no known cloud provider and remains in the old preferences. Choose its provider, then move the older settings to Keychain."
        }
    }
}
