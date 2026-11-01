import Security
import XCTest

@testable import MarkdownIt

final class CredentialTests: XCTestCase {
    func testSendingPermissionPersistsForTheServiceAcrossModelsAndProtocols() throws {
        let name = "dev.catli.MarkdownIt.consent-testing." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let consent = ModelDataConsent(defaults: defaults)
        let service = try ModelDataConsent.service(
            for: ModelConfiguration(baseURL: "https://API.Example.test:443/v1/", model: "first"))
        XCTAssertEqual(service.absoluteString, "https://api.example.test/v1")
        XCTAssertFalse(consent.allows(service))
        consent.allow(service)
        consent.allow(service)

        let restored = ModelDataConsent(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
        for base in [
            "https://api.example.test/v1", "https://api.example.test/v1/responses",
            "https://api.example.test/v1/chat/completions/", "https://api.example.test/v1/models",
        ] {
            let configuration = ModelConfiguration(baseURL: base, model: "another", apiProtocol: .chatCompletions)
            XCTAssertTrue(try restored.allows(ModelDataConsent.service(for: configuration)))
        }
        let stored = try XCTUnwrap(defaults.persistentDomain(forName: name))
        let values = try XCTUnwrap(stored["model.dataSharing.allowedServices.images"] as? [String])
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].count, 64)
        XCTAssertFalse(values[0].contains("example"))
    }

    func testSendingPermissionDoesNotExtendToAnotherDestination() throws {
        let name = "dev.catli.MarkdownIt.consent-testing." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let consent = ModelDataConsent(defaults: defaults)
        consent.allow(try ModelDataConsent.service(for: ModelConfiguration(baseURL: "https://example.test/v1")))
        for base in [
            "https://other.test/v1", "https://example.test/other/v1", "http://example.test/v1",
            "https://example.test:8443/v1", "https://example.test/V1",
        ] {
            XCTAssertFalse(try consent.allows(ModelDataConsent.service(for: ModelConfiguration(baseURL: base))))
        }
        for base in [
            "file:///tmp/private", "https://user:password@example.test/v1", "https://example.test/v1?key=test",
        ] {
            XCTAssertThrowsError(try ModelDataConsent.service(for: ModelConfiguration(baseURL: base)))
        }
    }

    private func temporaryDefaults() throws -> UserDefaults {
        let name = "dev.catli.MarkdownIt.settings-testing." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            let cleanup = try XCTUnwrap(UserDefaults(suiteName: name))
            cleanup.removePersistentDomain(forName: name)
        }
        return defaults
    }

    private func seed(_ data: Data, account: String, store: ModelSettingsStore) throws {
        let status = SecItemAdd(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: store.service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private func assertItemMissing(
        account: String, store: ModelSettingsStore, file: StaticString = #filePath, line: UInt = #line
    ) {
        let status = SecItemCopyMatching(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: store.service,
                kSecAttrAccount as String: account,
            ] as CFDictionary, nil)
        XCTAssertEqual(status, errSecItemNotFound, file: file, line: line)
    }

    @MainActor
    func testCompleteConnectionRestoresWithoutLocalPreferencesAndResetRemovesIt() throws {
        let store = isolatedModelSettings()
        let defaults = try temporaryDefaults()
        let settings = SavedModelSettings(
            configuration: .init(
                baseURL: "https://example.test/v1", model: "chosen-model", apiProtocol: .chatCompletions),
            apiKey: "keychain-test-only")
        let session = ReaderSession(defaults: defaults, modelSettings: store)
        XCTAssertFalse(session.isModelConfigured)
        try session.saveConfiguration(settings.configuration, key: settings.apiKey)
        XCTAssertEqual(try store.load(migrating: defaults), settings)
        XCTAssertNil(defaults.object(forKey: "model.baseURL"))
        XCTAssertNil(defaults.object(forKey: "model.id"))
        XCTAssertNil(defaults.object(forKey: "model.apiProtocol"))

        // A new preferences container models a reinstall without touching normal credentials.
        let restored = ReaderSession(defaults: try temporaryDefaults(), modelSettings: store)
        XCTAssertEqual(restored.configuration, settings.configuration)
        XCTAssertEqual(restored.apiKey, settings.apiKey)
        XCTAssertTrue(restored.isModelConfigured)
        XCTAssertNil(restored.modelSettingsError)
        restored.requestAgentEntry(id: "restored", token: restored.documentToken)
        XCTAssertFalse(restored.needsModelConfiguration)

        try restored.resetModelSettings()
        XCTAssertEqual(restored.configuration, ModelConfiguration())
        XCTAssertTrue(restored.apiKey.isEmpty)
        XCTAssertFalse(restored.isModelConfigured)
        assertItemMissing(account: "connection", store: store)
        assertItemMissing(account: "api-key", store: store)
        let reopened = ReaderSession(defaults: defaults, modelSettings: store)
        XCTAssertFalse(reopened.isModelConfigured)
        XCTAssertTrue(reopened.apiKey.isEmpty)
        try reopened.saveConfiguration(.init(), key: "")
        assertItemMissing(account: "connection", store: store)
    }

    func testLegacySettingsMigrateTogetherAndDoNotReplaceTheNewConnection() throws {
        let store = isolatedModelSettings()
        let defaults = try temporaryDefaults()
        defaults.set("https://legacy.example.test/v1", forKey: "model.baseURL")
        defaults.set("legacy-model", forKey: "model.id")
        defaults.set("chatCompletions", forKey: "model.apiProtocol")
        defaults.set("untouched", forKey: "unrelated.preference")
        try seed(Data("legacy-test-only-key".utf8), account: "api-key", store: store)
        let expected = SavedModelSettings(
            configuration: .init(
                baseURL: "https://legacy.example.test/v1", model: "legacy-model", apiProtocol: .chatCompletions),
            apiKey: "legacy-test-only-key")
        XCTAssertEqual(try store.load(migrating: defaults), expected)
        assertItemMissing(account: "api-key", store: store)
        XCTAssertNil(defaults.object(forKey: "model.baseURL"))
        XCTAssertNil(defaults.object(forKey: "model.id"))
        XCTAssertNil(defaults.object(forKey: "model.apiProtocol"))
        XCTAssertEqual(defaults.string(forKey: "unrelated.preference"), "untouched")

        defaults.set("https://stale.example.test/v1", forKey: "model.baseURL")
        try seed(Data("stale-test-only-key".utf8), account: "api-key", store: store)
        XCTAssertEqual(try store.load(migrating: defaults), expected)
        assertItemMissing(account: "api-key", store: store)
        XCTAssertNil(defaults.object(forKey: "model.baseURL"))
    }

    func testResetClearsCurrentAndLegacyItemsWithoutAffectingOtherServices() throws {
        let store = isolatedModelSettings()
        let other = isolatedModelSettings()
        let defaults = try temporaryDefaults()
        let expected = SavedModelSettings(
            configuration: .init(baseURL: "https://other.test/v1", model: "other"), apiKey: "other-test-only")
        try other.save(expected, replacingLegacyIn: defaults)
        try store.save(SavedModelSettings(apiKey: "reset-test-only"), replacingLegacyIn: defaults)
        try seed(Data("legacy-test-only".utf8), account: "api-key", store: store)
        defaults.set("old-model", forKey: "model.id")
        defaults.set("untouched", forKey: "unrelated.preference")
        try store.reset(clearingLegacyIn: defaults)
        try store.reset(clearingLegacyIn: defaults)
        assertItemMissing(account: "connection", store: store)
        assertItemMissing(account: "api-key", store: store)
        XCTAssertEqual(try store.load(migrating: defaults), SavedModelSettings())
        XCTAssertEqual(try other.load(migrating: defaults), expected)
        XCTAssertEqual(defaults.string(forKey: "unrelated.preference"), "untouched")
    }

    @MainActor
    func testUnreadableSettingsAreReportedRatherThanTreatedAsUnconfigured() throws {
        let store = isolatedModelSettings()
        let defaults = try temporaryDefaults()
        defaults.set("preserved-model", forKey: "model.id")
        try seed(Data("invalid-settings-json".utf8), account: "connection", store: store)
        XCTAssertThrowsError(try store.load(migrating: defaults))
        XCTAssertEqual(defaults.string(forKey: "model.id"), "preserved-model")
        let session = ReaderSession(defaults: defaults, modelSettings: store)
        XCTAssertNotNil(session.modelSettingsError)
        session.requestAgentEntry(id: "unreadable", token: session.documentToken)
        XCTAssertFalse(session.needsModelConfiguration)
        XCTAssertEqual(session.errorMessage, session.modelSettingsError)
        try session.resetModelSettings()
        XCTAssertNil(session.modelSettingsError)
        XCTAssertEqual(try store.load(migrating: defaults), SavedModelSettings())
    }
    func testTextOnlyConsentDoesNotAuthorizeSharingImagePixels() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = try ModelDataConsent.service(for: ModelConfiguration(baseURL: "https://example.test/v1"))
        let consent = ModelDataConsent(defaults: defaults)
        consent.allow(service)
        let imageGrant = try XCTUnwrap(defaults.stringArray(forKey: "model.dataSharing.allowedServices.images"))
        defaults.removeObject(forKey: "model.dataSharing.allowedServices.images")
        defaults.set(imageGrant, forKey: "model.dataSharing.allowedServices")
        let restored = ModelDataConsent(defaults: defaults)
        XCTAssertFalse(restored.allows(service), "An earlier text-only grant must not silently expand to image sharing")
        XCTAssertNil(defaults.object(forKey: "model.dataSharing.allowedServices"))
    }

}
