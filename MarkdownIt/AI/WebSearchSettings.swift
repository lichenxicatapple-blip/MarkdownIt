import Foundation

enum WebSearchProvider: String, Codable, CaseIterable, Sendable {
    case serper, tavily, brave

    var title: String {
        switch self {
        case .serper: "Serper"
        case .tavily: "Tavily"
        case .brave: "Brave Search"
        }
    }

    var endpoint: URL {
        switch self {
        case .serper: URL(string: "https://google.serper.dev/search")!
        case .tavily: URL(string: "https://api.tavily.com/search")!
        case .brave: URL(string: "https://api.search.brave.com/res/v1/web/search")!
        }
    }

    var extractionEndpoint: URL? {
        switch self {
        case .serper: URL(string: "https://scrape.serper.dev")!
        case .tavily: URL(string: "https://api.tavily.com/extract")!
        case .brave: nil
        }
    }

    func languageCode(_ language: String) -> String {
        let value = language.lowercased()
        switch value {
        case "zh", "zh-cn", "zh-hans": return self == .brave ? "zh-hans" : self == .serper ? "zh-cn" : "zh"
        case "zh-tw", "zh-hk", "zh-hant": return self == .brave ? "zh-hant" : self == .serper ? "zh-tw" : "zh"
        default: return value
        }
    }
}

/// Keys belong to individual services; disabling search retains them until Reset.
struct WebSearchSettings: Codable, Equatable, Sendable {
    var provider: WebSearchProvider?
    var keys: [String: String] = [:]

    var key: String { provider.flatMap { keys[$0.rawValue] } ?? "" }
    var isConfigured: Bool { provider != nil && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isEmpty: Bool { provider == nil && keys.isEmpty }
    var identity: String { provider.map { DocumentRevision.text($0.rawValue + ":" + key) } ?? "" }

    func validated() throws -> Self {
        var value = self
        value.keys = keys.compactMapValues {
            let key = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        }
        if value.provider != nil && !value.isConfigured { throw WebSearchSettingsError.missingKey }
        return value
    }
}

enum WebSearchSettingsError: LocalizedError {
    case missingKey
    var errorDescription: String? { String(localized: "Enter a search API key.") }
}

struct WebSearchConsent {
    private let defaults: UserDefaults
    private let key = "search.allowedServices.v2"

    init(defaults: UserDefaults) { self.defaults = defaults }

    func allows(_ provider: WebSearchProvider) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(provider.endpoint.host ?? "")
    }

    func allow(_ provider: WebSearchProvider) {
        var hosts = defaults.stringArray(forKey: key) ?? []
        guard let host = provider.endpoint.host, !hosts.contains(host) else { return }
        hosts.append(host)
        defaults.set(hosts, forKey: key)
    }
}
