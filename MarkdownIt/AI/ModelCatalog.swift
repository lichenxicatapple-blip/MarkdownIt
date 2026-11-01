import CryptoKit
import Foundation

struct CatalogModel: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String?
    var contextWindow: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case id, name
        case contextLength = "context_length"
        case contextWindow = "context_window"
    }

    init(id: String, name: String? = nil, contextWindow: Int? = nil) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        let capacity =
            (try? values.decode(Int.self, forKey: .contextLength))
            ?? (try? values.decode(Int.self, forKey: .contextWindow))
        contextWindow = capacity.flatMap { $0 > 0 ? $0 : nil }
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
        var request = URLRequest(url: try configuration.modelsEndpoint())
        request.httpMethod = "GET"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request, delegate: ModelRequestPolicy.shared)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ModelCatalogError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw ModelCatalogError.unavailable(response.statusCode)
        }
        struct Envelope: Decodable { var data: [CatalogModel] }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ModelCatalogError.invalidResponse
        }
        var seen: Set<String> = []
        return envelope.data.filter {
            !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
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

    func contextWindow(model: String, baseURL: String, key: String) -> Int? {
        guard let next = try? Self.connection(baseURL: baseURL, key: key), connection == next else { return nil }
        return cached?.first { $0.id == model.trimmingCharacters(in: .whitespacesAndNewlines) }?.contextWindow
    }

    private static func connection(baseURL: String, key: String) throws -> Connection {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.missingKey }
        return Connection(
            endpoint: try ModelConfiguration(baseURL: baseURL).modelsEndpoint(),
            credentialDigest: SHA256.hash(data: Data(key.utf8)))
    }
}
