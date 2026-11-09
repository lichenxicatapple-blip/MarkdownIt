import CoreFoundation
import Foundation

struct WebPageRequest {
    let url: URL
    let characterOffset: Any
    let query: Any

    init(arguments: String) throws {
        guard let object = try? ModelWireFormat.object(Data(arguments.utf8)),
            Set(object.keys) == ["url", "characterOffset", "query"],
            let value = object["url"] as? String, let url = URL(string: value),
            ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { throw WebPageError.arguments }
        // Validate types before a paid extraction; upper bounds depend on the fetched content.
        let offset = object["characterOffset"]!
        let query = object["query"]!
        if !(offset is NSNull) {
            guard let number = offset as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                number.doubleValue >= 0, number.doubleValue.rounded() == number.doubleValue,
                number.doubleValue < Double(Int.max)
            else { throw WebPageError.arguments }
        }
        guard query is NSNull || (query as? String)?.isEmpty == false else { throw WebPageError.arguments }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.fragment = nil
        self.url = components.url!
        characterOffset = offset
        self.query = query
    }
}

/// Full extraction stays native. Only pages actually requested by the model enter its context.
struct WebPageContent: Sendable {
    let url: URL
    let title: String
    let retrievedAt: String
    let format: String
    let content: String

    func excerpt(_ request: WebPageRequest, maxBytes: Int) throws -> WebPageExcerpt {
        let page = try AgentTextPage.read(
            content, characterOffset: request.characterOffset, query: request.query, maxBytes: maxBytes)
        return WebPageExcerpt(url: url, title: title, retrievedAt: retrievedAt, format: format, page: page)
    }
}

struct WebPageExcerpt: Codable, Sendable, Equatable {
    let url: URL
    let title: String
    let retrievedAt: String
    let format: String
    let page: AgentTextPage
}

enum WebPageError: Error {
    case arguments, unavailable

    var execution: AgentToolExecution {
        switch self {
        case .arguments:
            AgentToolExecution(
                output:
                    #"{"error":"invalid_arguments","message":"Use url, characterOffset and query only. url must be an HTTP(S) URL without embedded credentials. characterOffset is a zero-based Unicode character position within the extracted text, or null to start. query is nonempty text, or null for sequential reading."}"#
            )
        case .unavailable:
            AgentToolExecution(
                output:
                    #"{"error":"webpage_unavailable","message":"No readable page content was obtained. The page may be unavailable, require login or be unsupported by the extraction service. Do not claim to have read it."}"#
            )
        }
    }
}

extension WebSearchClient {
    func pageRequest(_ url: URL, provider: WebSearchProvider, key: String) throws -> URLRequest {
        guard let endpoint = provider.extractionEndpoint else { throw WebPageError.unavailable }
        guard !key.isEmpty else { throw WebSearchError.authentication }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        switch provider {
        case .serper:
            request.setValue(key, forHTTPHeaderField: "X-API-KEY")
            body = ["url": url.absoluteString]
        case .tavily:
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            body = [
                "urls": [url.absoluteString], "extract_depth": "basic", "format": "markdown",
                "include_images": false, "include_favicon": false,
            ]
        case .brave: throw WebPageError.unavailable
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        return request
    }

    func readPage(_ url: URL, provider: WebSearchProvider, key: String) async throws -> WebPageContent {
        // This bounds transport memory, not the model's context window. Oversized responses fail explicitly.
        let data = try await send(
            pageRequest(url, provider: provider, key: key), provider: provider, byteLimit: 4_000_000)
        return try decodePage(data, url: url, provider: provider)
    }

    func decodePage(_ data: Data, url: URL, provider: WebSearchProvider) throws -> WebPageContent {
        guard let root = try? ModelWireFormat.object(data), root["error"] == nil,
            (root["statusCode"] as? Int ?? 200) < 400
        else { throw WebPageError.unavailable }
        let content: String?
        let title: String?
        let format: String
        switch provider {
        case .serper:
            content = root["text"] as? String
            title = (root["metadata"] as? [String: Any])?["title"] as? String
            format = "text"
        case .tavily:
            // HTTP 200 can contain only failed_results. Never pass a provider error through as page text.
            let row = (root["results"] as? [[String: Any]])?.first { $0["url"] as? String == url.absoluteString }
            content = row?["raw_content"] as? String
            title = row?["title"] as? String
            format = "markdown"
        case .brave: throw WebPageError.unavailable
        }
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebPageError.unavailable
        }
        return WebPageContent(
            url: url, title: title ?? url.host ?? url.absoluteString, retrievedAt: Date().formatted(.iso8601),
            format: format, content: content)
    }
}
