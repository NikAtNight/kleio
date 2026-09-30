import Foundation
import XCTest
@testable import Scribe

final class SummaryCredentialTests: XCTestCase {
    private var domain: String!
    private var defaults: UserDefaults!
    private var credentials: TestSummaryCredentialStore!
    private var settings: SummarySettings!

    override func setUp() {
        super.setUp()
        domain = "test.summary-credentials.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
        credentials = TestSummaryCredentialStore()
        settings = SummarySettings(defaults: defaults, credentials: credentials)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        super.tearDown()
    }

    func testCloudKeysAndModelsStayWithTheirProvider() throws {
        try settings.saveAPIKey("anthropic-key", for: .anthropic)
        try settings.saveAPIKey("openai-key", for: .openai)
        defaults.set("claude-custom", forKey: "aiModel.anthropic")
        defaults.set("gpt-custom", forKey: "aiModel.openai")

        XCTAssertEqual(try settings.apiKey(for: .anthropic), "anthropic-key")
        XCTAssertEqual(try settings.apiKey(for: .openai), "openai-key")
        XCTAssertEqual(settings.model(for: .anthropic), "claude-custom")
        XCTAssertEqual(settings.model(for: .openai), "gpt-custom")
        XCTAssertNil(defaults.object(forKey: "aiAPIKey"))
        XCTAssertNil(defaults.object(forKey: "aiModel"))

        try settings.saveAPIKey("", for: .anthropic)
        XCTAssertEqual(try settings.apiKey(for: .anthropic), "")
        XCTAssertEqual(try settings.apiKey(for: .openai), "openai-key")
    }

    func testMigrationMovesSharedSettingsOnlyToSelectedCloudProvider() throws {
        defaults.set("openai", forKey: "aiProvider")
        defaults.set("legacy-openai-key", forKey: "aiAPIKey")
        defaults.set("legacy-openai-model", forKey: "aiModel")

        try settings.migrateLegacySettings()
        XCTAssertEqual(credentials.keys, [.openai: "legacy-openai-key"])
        XCTAssertNil(defaults.object(forKey: "aiAPIKey"))
        XCTAssertNil(defaults.object(forKey: "aiModel"))
        XCTAssertEqual(settings.model(for: .openai), "legacy-openai-model")
        XCTAssertEqual(settings.model(for: .anthropic), SummaryService.Provider.anthropic.defaultModel)
        XCTAssertEqual(try settings.apiKey(for: .anthropic), "")

        try settings.migrateLegacySettings()
        XCTAssertEqual(credentials.writes, [.openai])
    }

    func testMissingLegacyProviderUsesHistoricalAnthropicDefault() throws {
        defaults.set("legacy-key", forKey: "aiAPIKey")
        try settings.migrateLegacySettings()
        XCTAssertEqual(credentials.keys, [.anthropic: "legacy-key"])
    }

    func testFailedMigrationKeepsPlaintextAndOwnershipForRetry() throws {
        defaults.set("anthropic", forKey: "aiProvider")
        defaults.set("legacy-key", forKey: "aiAPIKey")
        defaults.set("legacy-model", forKey: "aiModel")
        credentials.writeError = TestSummaryCredentialStore.Failure.unavailable

        XCTAssertThrowsError(try settings.migrateLegacySettings())
        XCTAssertEqual(defaults.string(forKey: "aiAPIKey"), "legacy-key")
        XCTAssertEqual(defaults.string(forKey: "aiLegacyProvider"), "anthropic")

        defaults.set("openai", forKey: "aiProvider")
        XCTAssertEqual(try settings.apiKey(for: .openai), "")
        XCTAssertEqual(settings.model(for: .openai), SummaryService.Provider.openai.defaultModel)
        XCTAssertNil(credentials.keys[.openai])

        credentials.writeError = nil
        try settings.migrateLegacySettings()
        XCTAssertEqual(credentials.keys, [.anthropic: "legacy-key"])
        XCTAssertNil(defaults.object(forKey: "aiAPIKey"))
    }

    func testKeychainReadFailureDoesNotReplaceOrRemoveLegacyKey() {
        defaults.set("openai", forKey: "aiProvider")
        defaults.set("legacy-key", forKey: "aiAPIKey")
        credentials.readError = TestSummaryCredentialStore.Failure.unavailable

        XCTAssertThrowsError(try settings.migrateLegacySettings())
        XCTAssertEqual(defaults.string(forKey: "aiAPIKey"), "legacy-key")
        XCTAssertEqual(credentials.writes, [])
    }

    func testMigrationKeepsExistingProviderSettings() throws {
        defaults.set("openai", forKey: "aiProvider")
        defaults.set("legacy-key", forKey: "aiAPIKey")
        defaults.set("legacy-model", forKey: "aiModel")
        defaults.set("current-model", forKey: "aiModel.openai")
        credentials.keys[.openai] = "current-key"

        try settings.migrateLegacySettings()
        XCTAssertEqual(try settings.apiKey(for: .openai), "current-key")
        XCTAssertEqual(settings.model(for: .openai), "current-model")
        XCTAssertEqual(credentials.writes, [])
        XCTAssertNil(defaults.object(forKey: "aiAPIKey"))
    }

    func testUnknownOrLocalLegacyOwnerIsNeverReassignedOnProviderSwitch() throws {
        for rawProvider in ["ollama", "appleIntelligence", "claudeCode", "codex", "cursor", "unknown"] {
            defaults.removePersistentDomain(forName: domain)
            defaults.set(rawProvider, forKey: "aiProvider")
            defaults.set("ambiguous-key", forKey: "aiAPIKey")
            defaults.set("ambiguous-model", forKey: "aiModel")

            XCTAssertThrowsError(try settings.migrateLegacySettings()) { error in
                XCTAssertTrue(error is SummarySettings.MigrationError)
            }
            defaults.set("openai", forKey: "aiProvider")
            XCTAssertEqual(try settings.apiKey(for: .openai), "")
            XCTAssertEqual(settings.model(for: .openai), SummaryService.Provider.openai.defaultModel)
            XCTAssertEqual(defaults.string(forKey: "aiAPIKey"), "ambiguous-key")
        }
        XCTAssertTrue(credentials.keys.isEmpty)
    }

    func testSavingReplacementRemovesLegacyKeyOnlyAfterSuccessfulWrite() throws {
        defaults.set("openai", forKey: "aiProvider")
        defaults.set("legacy-key", forKey: "aiAPIKey")
        credentials.writeError = TestSummaryCredentialStore.Failure.unavailable
        XCTAssertThrowsError(try settings.saveAPIKey("replacement", for: .openai))
        XCTAssertEqual(defaults.string(forKey: "aiAPIKey"), "legacy-key")

        credentials.writeError = nil
        try settings.saveAPIKey(" replacement \n", for: .openai)
        XCTAssertEqual(try settings.apiKey(for: .openai), "replacement")
        XCTAssertNil(defaults.object(forKey: "aiAPIKey"))
    }

    func testExplicitProviderAssignmentMigratesAmbiguousSettings() throws {
        defaults.set("ollama", forKey: "aiProvider")
        defaults.set("ambiguous-key", forKey: "aiAPIKey")
        defaults.set("ambiguous-model", forKey: "aiModel")
        XCTAssertTrue(settings.needsLegacyProvider)

        try settings.assignLegacySettings(to: .openai)
        XCTAssertEqual(credentials.keys, [.openai: "ambiguous-key"])
        XCTAssertEqual(settings.model(for: .openai), "ambiguous-model")
        XCTAssertEqual(settings.model(for: .anthropic), SummaryService.Provider.anthropic.defaultModel)
        XCTAssertNil(defaults.object(forKey: "aiAPIKey"))
        XCTAssertFalse(settings.needsLegacyProvider)
    }

    func testExplicitProviderAssignmentRetainsOwnershipAfterFailedWrite() throws {
        defaults.set("cursor", forKey: "aiProvider")
        defaults.set("ambiguous-key", forKey: "aiAPIKey")
        credentials.writeError = TestSummaryCredentialStore.Failure.unavailable
        XCTAssertThrowsError(try settings.assignLegacySettings(to: .anthropic))
        XCTAssertEqual(defaults.string(forKey: "aiAPIKey"), "ambiguous-key")
        XCTAssertEqual(defaults.string(forKey: "aiLegacyProvider"), "anthropic")
        credentials.writeError = nil
        defaults.set("openai", forKey: "aiProvider")
        try settings.migrateLegacySettings()
        XCTAssertEqual(credentials.keys, [.anthropic: "ambiguous-key"])
    }

    func testLocalConfigurationDoesNotAccessKeychain() throws {
        defaults.set("ollama", forKey: "aiProvider")
        defaults.set("gemma3:4b", forKey: "aiOllamaModel")
        defaults.set("ambiguous-key", forKey: "aiAPIKey")
        credentials.readError = TestSummaryCredentialStore.Failure.unavailable
        credentials.writeError = TestSummaryCredentialStore.Failure.unavailable

        let configuration = try settings.configuration()
        XCTAssertEqual(configuration.model, "gemma3:4b")
        XCTAssertTrue(configuration.isConfigured)
        XCTAssertEqual(configuration.apiKey, "")
        XCTAssertEqual(credentials.reads, [])
        XCTAssertEqual(credentials.writes, [])
        for provider in [SummaryService.Provider.appleIntelligence, .claudeCode, .codex, .cursor] {
            defaults.set(provider.rawValue, forKey: "aiProvider")
            defaults.set("local-model", forKey: provider.modelDefaultsKey)
            let local = try settings.configuration()
            XCTAssertEqual(local.provider, provider)
            XCTAssertEqual(local.apiKey, "")
        }
        XCTAssertEqual(credentials.reads, [])
    }

    func testConfigurationCapturesOneProvidersCredentialsAndModel() throws {
        defaults.set("anthropic", forKey: "aiProvider")
        defaults.set("claude-custom", forKey: "aiModel.anthropic")
        credentials.keys = [.anthropic: "anthropic-key", .openai: "openai-key"]
        let captured = try settings.configuration()

        defaults.set("openai", forKey: "aiProvider")
        XCTAssertEqual(captured.provider, .anthropic)
        XCTAssertEqual(captured.apiKey, "anthropic-key")
        XCTAssertEqual(captured.model, "claude-custom")
    }

    func testOwnershipCapturedBeforeProviderChangeKeepsLegacyKeyWithOriginalVendor() throws {
        defaults.set("anthropic", forKey: "aiProvider")
        defaults.set("legacy-key", forKey: "aiAPIKey")
        settings.captureLegacyProvider()
        defaults.set("openai", forKey: "aiProvider")

        XCTAssertEqual(try settings.apiKey(for: .openai), "")
        try settings.migrateLegacySettings()
        XCTAssertEqual(credentials.keys, [.anthropic: "legacy-key"])
    }

    func testGenerationReportsKeychainFailureBeforeMakingARequest() async {
        defaults.set("anthropic", forKey: "aiProvider")
        credentials.readError = TestSummaryCredentialStore.Failure.unavailable
        do {
            _ = try await SummaryService.summarize(ScribeDocument(title: "Test", kind: .recording, status: .ready),
                                                   settings: settings)
            XCTFail("An unreadable credential must stop generation")
        } catch {
            XCTAssertTrue(error is TestSummaryCredentialStore.Failure)
        }
    }

    func testBackupIncludesProviderModelsAndExcludesKeys() {
        let backedUp = LibraryBackup.selectedPreferences([
            "aiModel.anthropic": "claude-custom", "aiModel.openai": "gpt-custom",
            "aiLegacyProvider": "openai", "aiAPIKey": "legacy-secret"
        ])
        XCTAssertEqual(backedUp["aiModel.anthropic"] as? String, "claude-custom")
        XCTAssertEqual(backedUp["aiModel.openai"] as? String, "gpt-custom")
        XCTAssertNil(backedUp["aiLegacyProvider"])
        XCTAssertNil(backedUp["aiAPIKey"])
    }
}

final class TestSummaryCredentialStore: SummaryCredentialStore {
    var keys: [SummaryService.Provider: String] = [:]
    var readError: Error?
    var writeError: Error?
    var reads: [SummaryService.Provider] = []
    var writes: [SummaryService.Provider] = []

    func apiKey(for provider: SummaryService.Provider) throws -> String? {
        reads.append(provider)
        if let readError { throw readError }
        return keys[provider]
    }

    func saveAPIKey(_ key: String, for provider: SummaryService.Provider) throws {
        if let writeError { throw writeError }
        writes.append(provider)
        keys[provider] = key.isEmpty ? nil : key
    }

    enum Failure: Error { case unavailable }
}
