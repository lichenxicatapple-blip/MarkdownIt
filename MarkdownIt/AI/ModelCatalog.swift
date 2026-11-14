import CryptoKit
import Foundation

struct CatalogModel: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String?
    var contextWindow: Int? = nil
    var maxInputTokens: Int? = nil
    var maxOutputTokens: Int? = nil

    var capabilities: ModelCapabilities {
        ModelCapabilities(
            contextWindow: contextWindow, maxInputTokens: maxInputTokens, maxOutputTokens: maxOutputTokens)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, model
        case displayName = "display_name"
        case contextLength = "context_length"
        case contextWindow = "context_window"
        case maxInputTokens = "max_input_tokens"
        case maxOutputTokens = "max_output_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case maxOutputLength = "max_output_length"
        case maxTokens = "max_tokens"
        case modelInfo = "model_info"
        case topProvider = "top_provider"
    }

    init(
        id: String, name: String? = nil, contextWindow: Int? = nil, maxInputTokens: Int? = nil,
        maxOutputTokens: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? values.decode(String.self, forKey: .model)
        name =
            try values.decodeIfPresent(String.self, forKey: .name)
            ?? values.decodeIfPresent(String.self, forKey: .displayName)
        let nested = try? values.nestedContainer(keyedBy: CodingKeys.self, forKey: .modelInfo)
        let provider = try? values.nestedContainer(keyedBy: CodingKeys.self, forKey: .topProvider)
        func positive(_ keys: CodingKeys...) -> Int? {
            for container in [provider, nested, values].compactMap({ $0 }) {
                for key in keys {
                    if let value = try? container.decode(Int.self, forKey: key), value > 0 { return value }
                }
            }
            return nil
        }
        contextWindow = positive(.contextLength, .contextWindow)
        maxInputTokens = positive(.maxInputTokens)
        maxOutputTokens = positive(.maxOutputTokens, .maxCompletionTokens, .maxOutputLength, .maxTokens)
    }

    func matches(search query: String) -> Bool {
        let query = Self.searchKey(query)
        return query.isEmpty || Self.searchKey(id).localizedStandardContains(query)
            || name.map { Self.searchKey($0).localizedStandardContains(query) } == true
    }

    private static func searchKey(_ value: String) -> String {
        value.filter { !$0.isWhitespace && $0 != "-" }
    }
}

enum ModelCatalogError: Error {
    case unavailable(Int)
    case invalidResponse
}

struct ModelCatalog: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        self.session = session ?? URLSession(configuration: configuration)
    }

    func models(baseURL: String, key: String) async throws -> [CatalogModel] {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.missingKey }
        let configuration = ModelConfiguration(baseURL: baseURL)
        var endpoint = try configuration.modelsEndpoint()
        // The native Qwen catalog exposes limits omitted by its compatibility
        // endpoint. Keep credentials on the same origin and workspace path.
        let host = endpoint.host?.lowercased() ?? ""
        if Self.isQwenHost(host), endpoint.path.hasSuffix("/compatible-mode/v1/models") {
            endpoint = endpoint.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("api/v1/models")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if host == "api.anthropic.com" { request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version") }
        return try await page(request, pageNumber: 1)
    }

    private func page(_ request: URLRequest, pageNumber: Int, previous: [CatalogModel] = []) async throws
        -> [CatalogModel]
    {
        let (data, response) = try await session.data(for: request, delegate: ModelRequestPolicy.shared)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ModelCatalogError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw ModelCatalogError.unavailable(response.statusCode)
        }
        struct Envelope: Decodable {
            struct Output: Decodable {
                var models: [CatalogModel]
                var total: Int?
            }
            var data: [CatalogModel]?
            var output: Output?
            var hasMore: Bool?
            var lastID: String?
            private enum CodingKeys: String, CodingKey {
                case data, output
                case hasMore = "has_more"
                case lastID = "last_id"
            }
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ModelCatalogError.invalidResponse
        }
        guard let models = envelope.data ?? envelope.output?.models else { throw ModelCatalogError.invalidResponse }
        let all = previous + models
        let more = envelope.hasMore == true || (envelope.output?.total.map { all.count < $0 } ?? false)
        if more {
            guard !Set(models.map(\.id)).subtracting(previous.map(\.id)).isEmpty else {
                throw ModelCatalogError.invalidResponse
            }
        }
        if let total = envelope.output?.total, all.count < total {
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "page_no", value: String(pageNumber + 1))]
            var next = request
            next.url = components.url
            return try await page(next, pageNumber: pageNumber + 1, previous: all)
        }
        if envelope.hasMore == true {
            guard let last = envelope.lastID, models.contains(where: { $0.id == last }) else {
                throw ModelCatalogError.invalidResponse
            }
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "after_id", value: last)]
            var next = request
            next.url = components.url
            return try await page(next, pageNumber: pageNumber + 1, previous: all)
        }
        var seen: Set<String> = []
        return all.filter {
            !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func isQwenHost(_ host: String) -> Bool {
        ["dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com", "dashscope-us.aliyuncs.com"].contains(host)
            || host.hasSuffix(".maas.aliyuncs.com")
    }
}

/// Cache entries hold a decoded catalog, endpoint and credential digest in memory.
/// Settings prefetch; opening the choice page joins that request or reads the cache.
@MainActor
final class ModelCatalogCache {
    typealias Loader = @Sendable (String, String) async throws -> [CatalogModel]
    private struct Connection: Equatable {
        var endpoint: URL
        var credentialDigest: SHA256.Digest
    }
    private let load: Loader
    private var connection: Connection?
    private var cached: [CatalogModel]?
    private var request: Task<[CatalogModel], Error>?
    private var requestID: UUID?
    private var debouncing = false

    init(load: @escaping Loader) { self.load = load }

    deinit { request?.cancel() }

    func prefetch(baseURL: String, key: String, debounce: Duration = .zero) {
        cancel()
        guard let next = try? Self.connection(baseURL: baseURL, key: key) else { return }
        if connection != next { cached = nil }
        connection = next
        let id = UUID()
        requestID = id
        debouncing = debounce > .zero
        let load = load
        request = Task { [weak self] in
            if debounce > .zero { try await Task.sleep(for: debounce) }
            try Task.checkCancellation()
            self?.debouncing = false
            let models = try await load(baseURL, key)
            try Task.checkCancellation()
            if self?.requestID == id, self?.connection == next { self?.cached = models }
            return models
        }
    }

    func models(baseURL: String, key: String) async throws -> [CatalogModel] {
        let next = try Self.connection(baseURL: baseURL, key: key)
        if connection != next || request == nil { prefetch(baseURL: baseURL, key: key) }
        if let cached { return cached }
        // An explicit tap need not wait for the typing debounce to expire.
        if debouncing { prefetch(baseURL: baseURL, key: key) }
        guard let request else { throw ModelError.configuration }
        return try await request.value
    }

    func cancel() {
        request?.cancel()
        request = nil
        requestID = nil
        debouncing = false
    }

    func reset() {
        cancel()
        connection = nil
        cached = nil
    }

    func capabilities(configuration: ModelConfiguration, key: String) async -> ModelCapabilities {
        let models = try? await models(baseURL: configuration.baseURL, key: key)
        let remote = models?.first { $0.id == configuration.model.trimmingCharacters(in: .whitespacesAndNewlines) }
        let bundled = BundledModelCatalog.shared?.capabilities(for: configuration) ?? ModelCapabilities()
        return (remote?.capabilities ?? ModelCapabilities()).fillingMissing(from: bundled)
    }

    private static func connection(baseURL: String, key: String) throws -> Connection {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.missingKey }
        return Connection(
            endpoint: try ModelConfiguration(baseURL: baseURL).modelsEndpoint(),
            credentialDigest: SHA256.hash(data: Data(key.utf8)))
    }
}
