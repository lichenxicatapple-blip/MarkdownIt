import XCTest

@testable import MarkdownIt

final class WebSearchFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var status = 200
    private var body = Data()
    private var suspended = false
    private var cancellations = 0

    func reset(status: Int = 200, body: Data = WebSearchFixture.success, suspended: Bool = false) {
        lock.withLock {
            requests = []
            self.status = status
            self.body = body
            self.suspended = suspended
            cancellations = 0
        }
    }
    func response(_ request: URLRequest) -> (Int, Data, Bool) {
        lock.withLock {
            requests.append(request)
            return (status, body, suspended)
        }
    }
    func captured() -> [URLRequest] { lock.withLock { requests } }
    func cancelled() { lock.withLock { cancellations += 1 } }
    func cancellationCount() -> Int { lock.withLock { cancellations } }
}

enum WebSearchFixture {
    static let state = WebSearchFixtureState()
    static let success = Data(
        #"{"organic":[{"title":"A public source","link":"https://source.example.org/reading","snippet":"Verified external information.","date":"2026-11-09"}]}"#
            .utf8)

    static func client() -> WebSearchClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebSearchFixtureProtocol.self]
        return WebSearchClient(session: URLSession(configuration: configuration))
    }
}

private final class WebSearchFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        WebSearchProvider.allCases.contains {
            $0.endpoint.host == request.url?.host || $0.extractionEndpoint?.host == request.url?.host
        }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = data
        }
        let (status, data, suspended) = WebSearchFixture.state.response(captured)
        if suspended { return }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { WebSearchFixture.state.cancelled() }
}

@MainActor
final class WebSearchTests: AgentReaderTestCase {

    func testProviderRequestsKeepUnicodeQueriesAndCredentialsInSeparateHeaders() throws {
        let query = try WebSearchQuery(arguments: #"{"query":"慢慢读 Markdown + café","language":"zh-Hans"}"#)
        for provider in WebSearchProvider.allCases {
            let request = try WebSearchFixture.client().request(query, provider: provider, key: "search-test-only")
            XCTAssertEqual(request.url?.host, provider.endpoint.host)
            XCTAssertFalse(request.url!.absoluteString.contains("search-test-only"))
            let body = try request.httpBody.map { try ModelWireFormat.object($0) }
            switch provider {
            case .serper:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-KEY"), "search-test-only")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(body?["q"] as? String, query.query)
                XCTAssertEqual(body?["hl"] as? String, "zh-cn")
                XCTAssertEqual(body?["num"] as? Int, 10)
            case .tavily:
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer search-test-only")
                XCTAssertNil(request.value(forHTTPHeaderField: "X-API-KEY"))
                XCTAssertEqual(body?["query"] as? String, query.query)
                XCTAssertEqual(body?["language"] as? String, "zh")
                XCTAssertEqual(body?["include_raw_content"] as? Bool, false)
                XCTAssertEqual(body?["include_answer"] as? Bool, false)
            case .brave:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "search-test-only")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let values = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(values?.first { $0.name == "q" }?.value, query.query)
                XCTAssertEqual(values?.first { $0.name == "search_lang" }?.value, "zh-hans")
                XCTAssertEqual(values?.first { $0.name == "count" }?.value, "10")
                XCTAssertNil(request.httpBody)
            }
        }
        let italian = try WebSearchQuery(arguments: #"{"query":"lettura markdown","language":"it"}"#)
        let request = try WebSearchFixture.client().request(italian, provider: .serper, key: "dummy")
        XCTAssertEqual(try ModelWireFormat.object(request.httpBody!)["hl"] as? String, "it")
    }

    func testStrictArgumentsRejectExtraFieldsBlankQueriesAndInvalidLanguage() throws {
        for arguments in [
            "broken JSON", #"{"query":"test"}"#, #"{"query":" ","language":null}"#,
            #"{"query":"test","language":123}"#, #"{"query":"test","language":"https://example.org"}"#,
            #"{"query":"test","language":null,"url":"https://example.org"}"#,
            #"{"query":"test","language":null,"apiKey":"not-allowed"}"#,
        ] { XCTAssertThrowsError(try WebSearchQuery(arguments: arguments)) }
        let large = try JSONSerialization.data(withJSONObject: [
            "query": String(repeating: "word ", count: 76), "language": NSNull(),
        ])
        XCTAssertThrowsError(try WebSearchQuery(arguments: String(decoding: large, as: UTF8.self)))
        let exact = try JSONSerialization.data(withJSONObject: [
            "query": String(repeating: "中", count: 600), "language": NSNull(),
        ])
        XCTAssertEqual(try WebSearchQuery(arguments: String(decoding: exact, as: UTF8.self)).query.count, 600)
    }

    func testProviderResponsesNormalizeSourcesAndKeepOnlySafeUniqueURLs() throws {
        let client = WebSearchFixture.client()
        for provider in WebSearchProvider.allCases {
            let rows: [[String: Any]] = [
                [
                    "title": "真实来源", "link": "https://source.example.org/one", "url": "https://source.example.org/one",
                    "snippet": "片段", "content": "片段", "description": "片段", "date": "2026-11-09",
                ],
                ["title": "重复", "link": "https://source.example.org/one", "url": "https://source.example.org/one"],
                ["title": "非法", "link": "javascript:alert(1)", "url": "javascript:alert(1)"],
                [
                    "title": "带凭据", "link": "https://name:password@source.example.org/",
                    "url": "https://name:password@source.example.org/",
                ],
            ]
            let root: [String: Any] =
                switch provider {
                case .serper: ["organic": rows]
                case .tavily: ["results": rows]
                case .brave: ["web": ["results": rows]]
                }
            let result = try client.decode(
                JSONSerialization.data(withJSONObject: root), provider: provider, query: "问题")
            XCTAssertEqual(result.results.count, 1)
            XCTAssertEqual(result.results.first?.title, "真实来源")
            XCTAssertEqual(result.results.first?.snippet, "片段")
            XCTAssertEqual(result.results.first?.publishedDate, "2026-11-09")
            XCTAssertNotNil(ISO8601DateFormatter().date(from: result.searchedAt))
        }
        XCTAssertTrue(
            try client.decode(Data(#"{"searchParameters":{"q":"none"}}"#.utf8), provider: .serper, query: "none")
                .results.isEmpty)
        XCTAssertTrue(
            try client.decode(Data(#"{"query":{"original":"none"}}"#.utf8), provider: .brave, query: "none").results
                .isEmpty)
        XCTAssertTrue(
            try client.decode(Data(#"{"results":[]}"#.utf8), provider: .tavily, query: "none").results.isEmpty)
        XCTAssertThrowsError(try client.decode(Data("{}".utf8), provider: .tavily, query: "none"))
        XCTAssertThrowsError(
            try client.decode(Data(#"{"error":"dummy-secret"}"#.utf8), provider: .serper, query: "none"))
    }

    func testNativeSearchErrorsNeverLeakKeysAndDoNotRetryOrFollowRedirects() async throws {
        let query = try WebSearchQuery(arguments: #"{"query":"public information","language":null}"#)
        for status in [401, 403, 402, 429, 302, 500] {
            WebSearchFixture.state.reset(status: status, body: Data(#"{"error":"search-test-secret"}"#.utf8))
            do {
                _ = try await WebSearchFixture.client().search(query, provider: .serper, key: "search-test-secret")
                XCTFail("Search must fail for HTTP \(status)")
            } catch let error as WebSearchError {
                XCTAssertFalse(error.message.contains("search-test-secret"))
                XCTAssertFalse(error.execution.output.contains("search-test-secret"))
                XCTAssertEqual(
                    error.code,
                    [401, 403].contains(status)
                        ? "search_authentication"
                        : status == 402 ? "search_quota" : status == 429 ? "search_rate_limit" : "search_service")
            }
            XCTAssertEqual(WebSearchFixture.state.captured().count, 1)
        }
    }

    func testTavilyPlanLimitsAreReportedAsQuotaWithoutAutomaticRetries() async throws {
        let query = try WebSearchQuery(arguments: #"{"query":"public information","language":null}"#)
        for status in [432, 433] {
            WebSearchFixture.state.reset(status: status)
            do {
                _ = try await WebSearchFixture.client().search(query, provider: .tavily, key: "test-only")
                XCTFail("The provider quota must be reported")
            } catch let error as WebSearchError {
                XCTAssertEqual(error.code, "search_quota")
            }
            XCTAssertEqual(WebSearchFixture.state.captured().count, 1)
        }
    }

    func testStoppingCancelsAnInFlightNativeSearch() async throws {
        WebSearchFixture.state.reset(suspended: true)
        let query = try WebSearchQuery(arguments: #"{"query":"public information","language":null}"#)
        let task = Task {
            try await WebSearchFixture.client().search(query, provider: .serper, key: "cancel-test-only")
        }
        try await wait { WebSearchFixture.state.captured().count == 1 }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not produce results")
        } catch is CancellationError {}
        try await wait { WebSearchFixture.state.cancellationCount() > 0 }
        XCTAssertEqual(WebSearchFixture.state.captured().count, 1)
    }

    func testWebPageProvidersUseFixedEndpointsAndValidateArgumentsBeforeExtraction() throws {
        let url = URL(string: "https://source.example.org/article")!
        for provider in [WebSearchProvider.serper, .tavily] {
            let request = try WebSearchFixture.client().pageRequest(url, provider: provider, key: "page-test-key")
            XCTAssertEqual(request.url, provider.extractionEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertFalse(request.url!.absoluteString.contains("page-test-key"))
            let body = try ModelWireFormat.object(XCTUnwrap(request.httpBody))
            if provider == .serper {
                XCTAssertEqual(body["url"] as? String, url.absoluteString)
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-KEY"), "page-test-key")
            } else {
                XCTAssertEqual(body["urls"] as? [String], [url.absoluteString])
                XCTAssertEqual(body["format"] as? String, "markdown")
                XCTAssertNil(body["query"], "Query-based extraction would return selected chunks instead of full text")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer page-test-key")
            }
        }
        XCTAssertThrowsError(try WebSearchFixture.client().pageRequest(url, provider: .brave, key: "dummy"))
        for arguments in [
            "broken JSON", #"{"url":"file:///private/file","characterOffset":null,"query":null}"#,
            #"{"url":"javascript:alert(1)","characterOffset":null,"query":null}"#,
            #"{"url":"https://name:password@example.org/","characterOffset":null,"query":null}"#,
            #"{"url":"https://example.org/","characterOffset":true,"query":null}"#,
            #"{"url":"https://example.org/","characterOffset":1.5,"query":null}"#,
            #"{"url":"https://example.org/","characterOffset":-1,"query":null}"#,
            #"{"url":"https://example.org/","characterOffset":null,"query":""}"#,
            #"{"url":"https://example.org/","characterOffset":null,"query":null,"key":"forbidden"}"#,
        ] { XCTAssertThrowsError(try WebPageRequest(arguments: arguments)) }
        for provider in WebSearchProvider.allCases {
            let tools = AgentWebSearch(
                settings: .init(provider: provider, keys: [provider.rawValue: "test-only"]),
                client: WebSearchFixture.client(), authorize: { _ in true }
            ).definitions
            XCTAssertEqual(tools.contains { $0.name == "read_webpage" }, provider != .brave)
        }
    }

    func testWebPagePagingAndFindReuseOneExtractionWithUnicodeCoordinates() async throws {
        let text = "😀中文e\u{301}🇨🇳👨‍👩‍👧‍👦\n" + String(repeating: "阅读 café。\n", count: 20)
        WebSearchFixture.state.reset(
            body: try JSONSerialization.data(withJSONObject: [
                "text": text, "metadata": ["title": "阅读材料"],
            ]))
        var grants = 0
        var recorded: [WebPageExcerpt] = []
        let tool = AgentWebSearch(
            settings: .init(provider: .serper, keys: ["serper": "page-secret-only"]),
            client: WebSearchFixture.client(), onPage: { recorded.append($0) },
            authorize: { _ in
                grants += 1
                return true
            })
        func call(offset: Any, query: Any = NSNull()) throws -> ModelToolCall {
            .init(
                id: UUID().uuidString, name: "read_webpage",
                arguments: String(
                    decoding: try JSONSerialization.data(
                        withJSONObject: [
                            "url": "https://source.example.org/article#section", "characterOffset": offset,
                            "query": query,
                        ]), as: UTF8.self))
        }
        var assembled = ""
        var offset: Int? = 0
        while let start = offset {
            let result = try await tool.execute(call(offset: start), maxReadBytes: 40)
            let excerpt = try JSONDecoder().decode(WebPageExcerpt.self, from: Data(result.output.utf8))
            XCTAssertEqual(excerpt.page.characterOffset, start)
            XCTAssertEqual(excerpt.page.totalCharacters, text.count)
            XCTAssertEqual(excerpt.title, "阅读材料")
            XCTAssertEqual(excerpt.url.absoluteString, "https://source.example.org/article")
            XCTAssertFalse(result.output.contains("page-secret-only"))
            assembled += excerpt.page.content
            offset = excerpt.page.nextCharacterOffset
        }
        XCTAssertEqual(assembled, text)
        let found = try await tool.execute(call(offset: NSNull(), query: "café"), maxReadBytes: 40)
        XCTAssertTrue(
            try JSONDecoder().decode(WebPageExcerpt.self, from: Data(found.output.utf8)).page.content.hasPrefix("café"))
        let missing = try await tool.execute(call(offset: NSNull(), query: "does-not-exist"))
        XCTAssertTrue(missing.output.contains("not_found"))
        let invalid = try await tool.execute(call(offset: text.count + 1))
        XCTAssertTrue(invalid.output.contains("invalid_arguments"))
        XCTAssertEqual(WebSearchFixture.state.captured().count, 1)
        XCTAssertEqual(grants, 1)
        XCTAssertGreaterThan(recorded.count, 1)
    }

    func testWebPageExtractionFailuresAndDeniedPermissionDoNotMasqueradeAsContent() async throws {
        let url = URL(string: "https://source.example.org/article")!
        let client = WebSearchFixture.client()
        for data in [
            Data(
                #"{"results":[],"failed_results":[{"url":"https://source.example.org/article","error":"provider-private-detail"}]}"#
                    .utf8),
            Data(#"{"results":[{"url":"https://other.example.org/article","raw_content":"Wrong page"}]}"#.utf8),
            Data(#"{"error":"provider-private-detail"}"#.utf8),
        ] { XCTAssertThrowsError(try client.decodePage(data, url: url, provider: .tavily)) }
        let page = try client.decodePage(
            Data(
                ##"{"results":[{"url":"https://source.example.org/article","raw_content":"# Article\n\nBody"}]}"##.utf8),
            url: url, provider: .tavily)
        XCTAssertEqual(page.format, "markdown")
        XCTAssertEqual(page.content, "# Article\n\nBody")
        WebSearchFixture.state.reset()
        let denied = AgentWebSearch(
            settings: .init(provider: .serper, keys: ["serper": "test-only"]), client: client,
            authorize: { provider in
                XCTAssertEqual(provider, .serper)
                return false
            })
        let result = try await denied.execute(
            .init(
                id: "denied-page", name: "read_webpage",
                arguments: #"{"url":"https://source.example.org/article","characterOffset":null,"query":null}"#))
        XCTAssertTrue(result.output.contains("search_permission"))
        XCTAssertTrue(denied.definitions.isEmpty)
        XCTAssertTrue(WebSearchFixture.state.captured().isEmpty)
    }

    func testSearchSettingsShareDurableKeychainStorageAndResetWithTheModel() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = isolatedModelSettings()
        let session = ReaderSession(defaults: defaults, modelSettings: store)
        let model = ModelConfiguration(baseURL: "https://model.example.org/v1", model: "test")
        let search = WebSearchSettings(
            provider: .serper, keys: ["serper": "serper-test-only", "brave": "brave-test-only"])
        try session.saveConfiguration(model, key: "model-test-only", search: search)
        let reopened = ReaderSession(defaults: defaults, modelSettings: store)
        XCTAssertEqual(reopened.searchSettings, search)
        XCTAssertEqual(reopened.apiKey, "model-test-only")
        var disabled = search
        disabled.provider = nil
        try reopened.saveConfiguration(model, key: reopened.apiKey, search: disabled)
        XCTAssertFalse(reopened.searchSettings.isConfigured)
        XCTAssertEqual(reopened.searchSettings.keys["brave"], "brave-test-only")
        try reopened.resetModelSettings()
        XCTAssertEqual(try store.load(migrating: defaults), SavedModelSettings())
        XCTAssertTrue(reopened.searchSettings.isEmpty)
        XCTAssertThrowsError(try WebSearchSettings(provider: .tavily).validated())
    }

    func testExistingConnectionDecodesWithSearchDisabled() throws {
        let data = Data(
            #"{"configuration":{"baseURL":"https://model.example.org/v1","model":"test","apiProtocol":"responses"},"apiKey":"old-test-only"}"#
                .utf8)
        let connection = try JSONDecoder().decode(SavedModelSettings.self, from: data)
        XCTAssertNil(connection.search)
        XCTAssertEqual(connection.apiKey, "old-test-only")
    }

    func testSearchPermissionCanBeDeclinedCancelledAndRememberedPerService() async throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["google.serper.dev"], forKey: "search.allowedServices")
        let authorization = WebSearchAuthorization(defaults: defaults)
        let declined = Task { await authorization.authorize(provider: .serper) { true } }
        try await wait { authorization.request != nil }
        authorization.finish(allowed: false)
        let wasDeclined = await declined.value
        XCTAssertFalse(wasDeclined)
        let cancelled = Task { await authorization.authorize(provider: .serper) { true } }
        try await wait { authorization.request != nil }
        cancelled.cancel()
        let wasCancelled = await cancelled.value
        XCTAssertFalse(wasCancelled)
        XCTAssertNil(authorization.request)
        let allowed = Task { await authorization.authorize(provider: .serper) { true } }
        try await wait { authorization.request != nil }
        authorization.finish(allowed: true)
        let wasAllowed = await allowed.value
        XCTAssertTrue(wasAllowed)
        let remembered = await authorization.authorize(provider: .serper) { true }
        XCTAssertTrue(remembered)
        let different = Task { await authorization.authorize(provider: .brave) { true } }
        try await wait { authorization.request?.provider == .brave }
        authorization.finish(allowed: false)
        let otherAllowed = await different.value
        XCTAssertFalse(otherAllowed)
    }
    func testPermissionPresentationResetDoesNotOverrideTheUserAction() async throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let authorization = WebSearchAuthorization(defaults: defaults)
        let task = Task { await authorization.authorize(provider: .serper) { true } }
        try await wait { authorization.request != nil }
        let id = try XCTUnwrap(authorization.request?.id)
        authorization.isPresented = false
        XCTAssertNotNil(
            authorization.request, "The system dismisses presentation before delivering the selected action")
        authorization.finish(allowed: true, id: id)
        let allowed = await task.value
        XCTAssertTrue(allowed)
        XCTAssertNil(authorization.request)
    }

}
