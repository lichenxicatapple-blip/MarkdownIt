import Foundation
import Security

struct SavedModelSettings: Codable, Equatable, Sendable {
    var configuration = ModelConfiguration()
    var apiKey = ""
    var search: WebSearchSettings?
}

/// One Keychain item keeps model and optional search connections and their credentials together.
struct ModelSettingsStore: Sendable {
    let service: String

    init(service: String = ModelSettingsStore.defaultService) {
        self.service = service
    }

    private static var defaultService: String {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                return "dev.catli.MarkdownIt.model.ui-testing"
            }
        #endif
        return "dev.catli.MarkdownIt.model"
    }

    func load(migrating defaults: UserDefaults) throws -> SavedModelSettings {
        if let data = try read(account: "connection") {
            let settings = try JSONDecoder().decode(SavedModelSettings.self, from: data)
            try removeLegacySettings(from: defaults)
            return settings
        }
        let key = try read(account: "api-key")
        let configuration = ModelConfiguration(
            baseURL: defaults.string(forKey: "model.baseURL") ?? "",
            model: defaults.string(forKey: "model.id") ?? "",
            apiProtocol: ModelAPIProtocol(rawValue: defaults.string(forKey: "model.apiProtocol") ?? "") ?? .responses)
        let settings = SavedModelSettings(
            configuration: configuration, apiKey: key.map { String(decoding: $0, as: UTF8.self) } ?? "")
        if key != nil || Self.legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) {
            try save(settings, replacingLegacyIn: defaults)
        }
        return settings
    }

    func save(_ settings: SavedModelSettings, replacingLegacyIn defaults: UserDefaults) throws {
        if settings == SavedModelSettings() {
            try reset(clearingLegacyIn: defaults)
            return
        }
        let data = try JSONEncoder().encode(settings)
        let query = query(account: "connection")
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
        // Preserve the old values until the complete replacement is durable.
        try removeLegacySettings(from: defaults)
    }

    func reset(clearingLegacyIn defaults: UserDefaults) throws {
        // Limit deletion to this app's model service, including the old key item.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        try check(SecItemDelete(query as CFDictionary), allowingMissing: true)
        for key in Self.legacyKeys { defaults.removeObject(forKey: key) }
    }

    private static let legacyKeys = ["model.baseURL", "model.id", "model.apiProtocol"]

    private func removeLegacySettings(from defaults: UserDefaults) throws {
        try check(SecItemDelete(query(account: "api-key") as CFDictionary), allowingMissing: true)
        for key in Self.legacyKeys { defaults.removeObject(forKey: key) }
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(account: String) throws -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = value as? Data else { throw CocoaError(.coderReadCorrupt) }
        return data
    }

    private func check(_ status: OSStatus, allowingMissing: Bool = false) throws {
        guard status == errSecSuccess || (allowingMissing && status == errSecItemNotFound) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
