import Foundation

struct WebSearchQuery: Sendable, Equatable {
    let query: String
    let language: String?

    init(arguments: String) throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
            Set(object.keys) == ["query", "language"], let query = object["query"] as? String,
            object["language"] is NSNull || object["language"] is String
        else { throw WebSearchError.arguments }
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.count <= 600,
            value.split(whereSeparator: \.isWhitespace).count <= 75
        else { throw WebSearchError.arguments }
        if let language = object["language"] as? String {
            guard language.range(of: "^[A-Za-z]{2,3}(-[A-Za-z]{2,8})?$", options: .regularExpression) != nil else {
                throw WebSearchError.arguments
            }
        }
        self.query = value
        language = (object["language"] as? String)?.lowercased()
    }
}

struct WebSearchResult: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable {
        let title: String
        let url: URL
        let snippet: String
        let publishedDate: String?
    }
    let query: String
    let searchedAt: String
    let results: [Item]
}

enum WebSearchError: Error {
    case arguments, authentication, quota, rateLimit, network, timeout, response, permission
    case service(Int)

    var code: String {
        switch self {
        case .arguments: "invalid_arguments"
        case .authentication: "search_authentication"
        case .quota: "search_quota"
        case .rateLimit: "search_rate_limit"
        case .network: "search_network"
        case .timeout: "search_timeout"
        case .response: "search_response"
        case .permission: "search_permission"
        case .service: "search_service"
        }
    }

    var message: String {
        switch self {
        case .arguments:
            "Use query and language only. query must be nonempty, at most 600 characters and 75 words. language must be an ISO language code such as en, it or zh-Hans, or null for provider defaults."
        case .authentication: "The search API key was rejected. Ask the user to check their search settings."
        case .quota: "Search credits or the account quota have been exhausted. Check the search service account."
        case .rateLimit: "The search service rate limited this request. Do not automatically retry."
        case .network: "The search service could not be reached. No search results were obtained."
        case .timeout: "The search request timed out. No search results were obtained."
        case .response: "The search service returned an invalid response. No search results were obtained."
        case .permission: "The user did not allow this search. Continue without searching and respect that choice."
        case .service(let status): "The search service returned HTTP \(status). No search results were obtained."
        }
    }

    var execution: AgentToolExecution {
        let data = try! JSONSerialization.data(
            withJSONObject: ["error": code, "message": message], options: .sortedKeys)
        return AgentToolExecution(output: String(decoding: data, as: UTF8.self))
    }
}

/// Provider adapters share one native, cancellable HTTP path. Credentials never enter tool results.
struct WebSearchClient: Sendable {
    private let session: URLSession
    // One search-results page, independent of the model's context budget.
    static let resultCount = 10
    private static let responseByteLimit = 1_000_000

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        self.session = session ?? URLSession(configuration: configuration)
    }

    func request(_ query: WebSearchQuery, provider: WebSearchProvider, key: String) throws -> URLRequest {
        guard !key.isEmpty else { throw WebSearchError.authentication }
        var request = URLRequest(url: provider.endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let language = query.language.map { provider.languageCode($0) }
        var body: [String: Any]
        switch provider {
        case .serper:
            body = ["q": query.query, "num": Self.resultCount]
            if let language { body["hl"] = language }
            request.setValue(key, forHTTPHeaderField: "X-API-KEY")
        case .tavily:
            body = [
                "query": query.query, "max_results": Self.resultCount, "search_depth": "basic",
                "include_answer": false, "include_raw_content": false, "include_images": false,
            ]
            if let language { body["language"] = language }
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        case .brave:
            var components = URLComponents(url: provider.endpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "q", value: query.query),
                URLQueryItem(name: "count", value: String(Self.resultCount)),
                URLQueryItem(name: "result_filter", value: "web"),
                URLQueryItem(name: "text_decorations", value: "false"),
            ]
            if let language { components.queryItems?.append(URLQueryItem(name: "search_lang", value: language)) }
            request.url = components.url
            request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
            return request
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        return request
    }

    func search(_ query: WebSearchQuery, provider: WebSearchProvider, key: String) async throws -> WebSearchResult {
        let data = try await send(request(query, provider: provider, key: key), provider: provider)
        return try decode(data, provider: provider, query: query.query)
    }

    func send(_ request: URLRequest, provider: WebSearchProvider, byteLimit: Int = responseByteLimit) async throws
        -> Data
    {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: ModelRequestPolicy.shared)
            guard let http = response as? HTTPURLResponse else { throw WebSearchError.response }
            switch http.statusCode {
            case 200...299: break
            case 401, 403: throw WebSearchError.authentication
            case 402: throw WebSearchError.quota
            case 432 where provider == .tavily, 433 where provider == .tavily: throw WebSearchError.quota
            case 429: throw WebSearchError.rateLimit
            default: throw WebSearchError.service(http.statusCode)
            }
            var data = Data()
            for try await byte in bytes.prefix(byteLimit + 1) { data.append(byte) }
            guard data.count <= byteLimit else { throw WebSearchError.response }
            return data
        } catch is CancellationError { throw CancellationError() } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw error.code == .timedOut ? WebSearchError.timeout : WebSearchError.network
        }
    }

    func decode(_ data: Data, provider: WebSearchProvider, query: String) throws -> WebSearchResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["error"] == nil, (root["statusCode"] as? Int ?? 200) < 400
        else { throw WebSearchError.response }
        let raw: Any?
        switch provider {
        case .serper: raw = root["organic"]
        case .tavily: raw = root["results"]
        case .brave: raw = (root["web"] as? [String: Any])?["results"]
        }
        // A valid empty SERP may omit its results group, while still identifying the query.
        let empty =
            (provider == .brave && root["query"] != nil)
            || (provider == .serper && root["searchParameters"] is [String: Any])
        let rows: [[String: Any]]
        if let raw {
            guard let values = raw as? [[String: Any]] else { throw WebSearchError.response }
            rows = values
        } else if empty {
            rows = []
        } else {
            throw WebSearchError.response
        }
        var seen = Set<URL>()
        let items = rows.compactMap { row -> WebSearchResult.Item? in
            guard let text = row[provider == .serper ? "link" : "url"] as? String,
                let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                seen.insert(url).inserted
            else { return nil }
            let snippet =
                row[provider == .tavily ? "content" : provider == .brave ? "description" : "snippet"] as? String
            return WebSearchResult.Item(
                title: row["title"] as? String ?? host, url: url, snippet: snippet ?? "",
                publishedDate: row["date"] as? String ?? row["published_date"] as? String ?? row["age"] as? String)
        }
        return WebSearchResult(
            query: query, searchedAt: Date().formatted(.iso8601), results: Array(items.prefix(Self.resultCount)))
    }
}
