import Foundation

/// Provider-declared limits. Missing values stay unknown, independently for each constraint.
struct ModelCapabilities: Codable, Equatable, Sendable {
    var contextWindow: Int?
    var maxInputTokens: Int?
    var maxOutputTokens: Int?

    init(contextWindow: Int? = nil, maxInputTokens: Int? = nil, maxOutputTokens: Int? = nil) {
        self.contextWindow = contextWindow.flatMap { $0 > 0 ? $0 : nil }
        self.maxInputTokens = maxInputTokens.flatMap { $0 > 0 ? $0 : nil }
        self.maxOutputTokens = maxOutputTokens.flatMap { $0 > 0 ? $0 : nil }
    }

    func fillingMissing(from other: Self) -> Self {
        Self(
            contextWindow: contextWindow ?? other.contextWindow,
            maxInputTokens: maxInputTokens ?? other.maxInputTokens,
            maxOutputTokens: maxOutputTokens ?? other.maxOutputTokens)
    }
}

/// A reviewed, offline supplement; exact service and model identities prevent cross-provider guesses.
struct BundledModelCatalog: Decodable, Sendable {
    struct Provider: Decodable, Sendable {
        let endpoints: [String]
        let models: [String: ModelCapabilities]
    }

    let schemaVersion: Int
    let revision: String
    let providers: [String: Provider]

    static let shared: Self? = {
        guard let url = Bundle.main.url(forResource: "model-capabilities", withExtension: "json"),
            let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Self.self, from: data),
            catalog.schemaVersion == 1
        else { return nil }
        return catalog
    }()

    func capabilities(for configuration: ModelConfiguration) -> ModelCapabilities {
        guard let service = try? ModelDataConsent.service(for: configuration) else { return ModelCapabilities() }
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: ModelCapabilities?
        for provider in providers.values {
            let matches = provider.endpoints.contains { endpoint in
                (try? ModelDataConsent.service(for: ModelConfiguration(baseURL: endpoint))) == service
            }
            if matches, let limits = provider.models[model] {
                if let result, result != limits { return ModelCapabilities() }
                result = limits
            }
        }
        return result ?? ModelCapabilities()
    }
}
