import Foundation
import Network
import XCTest

@testable import MarkdownIt

final class CurrentTimeToolTests: XCTestCase {
    func testCurrentTimeUsesISO8601AndSystemTimeZoneIncludingDaylightSaving() throws {
        let parser = ISO8601DateFormatter()
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        for (input, expected) in [
            ("2026-01-15T12:00:00Z", "2026-01-15T13:00:00+01:00"),
            ("2026-06-15T12:00:00Z", "2026-06-15T14:00:00+02:00"),
        ] {
            let call = ModelToolCall(id: "time", name: AgentCurrentTime.definition.name, arguments: "{}")
            let result = AgentCurrentTime.execute(call, now: try XCTUnwrap(parser.date(from: input)), timeZone: zone)
            let output = try ModelWireFormat.object(Data(result.output.utf8))
            XCTAssertEqual(output["currentTime"] as? String, expected)
            XCTAssertEqual(output["timeZone"] as? String, "Europe/Rome")
            XCTAssertNil(result.change)
        }
        XCTAssertFalse(AgentCurrentTime.definition.reusesResult, "Each invocation reads the current system clock")
    }

    func testCurrentTimeAcceptsOnlyTheDeclaredEmptyArguments() throws {
        let schema = try ModelWireFormat.object(AgentCurrentTime.definition.parameters)
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertTrue((schema["properties"] as? [String: Any])?.isEmpty == true)
        for arguments in ["null", "[]", "broken", #"{"timeZone":"UTC"}"#, #"{"date":"tomorrow"}"#] {
            let result = AgentCurrentTime.execute(
                ModelToolCall(id: "time", name: AgentCurrentTime.definition.name, arguments: arguments))
            let output = try ModelWireFormat.object(Data(result.output.utf8))
            XCTAssertEqual(output["error"] as? String, "invalid_arguments")
        }
    }
}

private final class MockResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var response = (status: 200, headers: ["Content-Type": "text/event-stream"], body: "")
    private var captured: URLRequest?
    private var count = 0
    private var pages: [String] = []
    func configure(
        status: Int = 200, mime: String = "text/event-stream", headers: [String: String] = [:], body: String,
        pages: [String] = []
    ) {
        lock.withLock {
            response = (status, headers.merging(["Content-Type": mime], uniquingKeysWith: { a, _ in a }), body)
            captured = nil
            count = 0
            self.pages = pages
        }
    }
    func record(_ request: URLRequest) -> (Int, [String: String], String) {
        lock.withLock {
            captured = request
            count += 1
            if !pages.isEmpty { return (response.status, response.headers, pages[min(count - 1, pages.count - 1)]) }
            return response
        }
    }
    func request() -> URLRequest? { lock.withLock { captured } }
    func requestCount() -> Int { lock.withLock { count } }
}

private final class ModelURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = MockResponseState()
    override class func canInit(with request: URLRequest) -> Bool {
        ["example.test", "api.deepseek.com", "api.anthropic.com", "dashscope.aliyuncs.com"].contains(
            request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            capturedRequest.httpBody = data
        }
        let (status, headers, body) = Self.fixture.record(capturedRequest)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Split UTF-8 bytes, including Chinese characters, across chunks.
        let data = Data(body.utf8)
        for offset in stride(from: 0, to: data.count, by: 7) {
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 7, data.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor AnswerCollector {
    var text = ""
    func append(_ value: String) { text += value }
}

private final class DiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ModelDiagnostics.Event] = []
    func append(_ event: ModelDiagnostics.Event) { lock.withLock { stored.append(event) } }
    func events() -> [ModelDiagnostics.Event] { lock.withLock { stored } }
}

/// A real loopback endpoint exercises URLSession's redirect delegate, including streamed POST bodies.
private final class RedirectFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MarkdownItTests.RedirectFixture")
    private let lock = NSLock()
    private var requests: [String] = []
    private let status: Int

    init(status: Int) throws {
        self.status = status
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.receive(connection)
        }
    }

    func start() async throws -> String {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port {
                        continuation.resume(returning: port.rawValue)
                    } else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return "http://127.0.0.1:\(port)/v1"
    }

    func stop() { listener.cancel() }
    func paths() -> [String] { lock.withLock { requests } }

    private func receive(_ connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            let request = buffered + (data ?? Data())
            guard let boundary = request.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { connection.cancel() } else { self.receive(connection, buffered: request) }
                return
            }
            let headers = String(decoding: request[..<boundary.lowerBound], as: UTF8.self).components(
                separatedBy: "\r\n")
            let length =
                headers.first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            if request.count < boundary.upperBound + length {
                if complete { connection.cancel() } else { self.receive(connection, buffered: request) }
                return
            }
            let path = headers.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            self.lock.withLock { self.requests.append(path) }
            let code = path == "/unapproved" ? 418 : self.status
            guard let port = self.listener.port else {
                connection.cancel()
                return
            }
            let response =
                "HTTP/1.1 \(code) Fixture\r\nLocation: http://127.0.0.1:\(port.rawValue)/unapproved\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private actor PendingCatalogLoads {
    private var requests: [(String, String)] = []
    private var pending: [Int: CheckedContinuation<[CatalogModel], Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func load(_ baseURL: String, _ key: String) async throws -> [CatalogModel] {
        let index = requests.count
        requests.append((baseURL, key))
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            let ready = observers.filter { $0.0 <= requests.count }
            observers.removeAll { $0.0 <= requests.count }
            for (_, observer) in ready { observer.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func respond(_ index: Int, _ result: Result<[CatalogModel], Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }

    func keys() -> [String] { requests.map(\.1) }
}

final class ModelClientTests: XCTestCase {
    func testModelRequestsDoNotRedirectToAnotherServicePath() async throws {
        for api in ModelAPIProtocol.allCases {
            let server = try RedirectFixtureServer(status: 307)
            defer { server.stop() }
            let baseURL = try await server.start()
            do {
                _ = try await ModelClient().stream(
                    configuration: ModelConfiguration(baseURL: baseURL, model: "test", apiProtocol: api),
                    key: "test-only-key", messages: [ChatMessage(role: "user", content: "Private document")]
                ) { _ in XCTFail("A redirect must not produce an answer") }
                XCTFail("The configured endpoint must report its redirect")
            } catch ModelError.service(let status, _) {
                XCTAssertEqual(status, 307)
            } catch {
                XCTFail("Expected the original redirect response, received \(error)")
            }
            XCTAssertEqual(server.paths(), ["/v1/" + api.path], "Do not forward the document to another path")
        }

        let server = try RedirectFixtureServer(status: 302)
        defer { server.stop() }
        let baseURL = try await server.start()
        do {
            _ = try await ModelCatalog().models(baseURL: baseURL, key: "test-only-key")
            XCTFail("The catalog must report the original redirect")
        } catch ModelCatalogError.unavailable(let status) {
            XCTAssertEqual(status, 302)
        } catch {
            XCTFail("Expected the original catalog redirect, received \(error)")
        }
        XCTAssertEqual(server.paths(), ["/v1/models"], "Do not forward credentials to another path")
    }

    func testCatalogSearchMatchesNamesAndIDsWithoutSpacesOrHyphens() {
        let byID = CatalogModel(id: "openai/gpt-6.1-sol")
        let byName = CatalogModel(id: "provider/123", name: "GPT 6.1 Sol")
        for query in ["gpt6.1", "gpt 6.1", "gpt-6.1", "GPT6.1", " \tGPT 6.1\n", "gpt\u{00A0}6.1"] {
            XCTAssertTrue(byID.matches(search: query), "ID should match \(query)")
            XCTAssertTrue(byName.matches(search: query), "Name should match \(query)")
        }
        XCTAssertTrue(byID.matches(search: "openai/gpt6.1sol"))
        XCTAssertTrue(byID.matches(search: " \n"))
    }

    func testCatalogSearchPreservesVersionDotsAndProviderSeparators() {
        let model = CatalogModel(id: "openai/gpt-6.1-sol", name: "GPT 6.1 Sol")
        for query in ["gpt61", "gpt6.2", "gpt6.10", "openaigpt6.1", "gpt_6.1"] {
            XCTAssertFalse(model.matches(search: query), "Must not erase punctuation in \(query)")
        }
        XCTAssertFalse(CatalogModel(id: "gpt-61").matches(search: "gpt6.1"))
        XCTAssertFalse(CatalogModel(id: "gpt-16.1").matches(search: "gpt6.1"))
    }

    @MainActor
    func testCatalogPrefetchAndMenuShareOneRequestAndRefreshKeepsCachedChoices() async throws {
        let loads = PendingCatalogLoads()
        let cache = ModelCatalogCache { try await loads.load($0, $1) }
        let base = "https://example.test/v1"
        cache.prefetch(baseURL: base, key: "key-a")
        await loads.waitForRequests(1)
        let menu = Task { try await cache.models(baseURL: base, key: "key-a") }
        await loads.respond(0, .success([CatalogModel(id: "cached-model")]))
        let models = try await menu.value
        XCTAssertEqual(models, [CatalogModel(id: "cached-model")])
        let firstKeys = await loads.keys()
        XCTAssertEqual(firstKeys, ["key-a"])

        cache.prefetch(baseURL: base, key: "key-a")
        await loads.waitForRequests(2)
        // This must return before the deliberately held refresh completes.
        let immediate = try await cache.models(baseURL: base, key: "key-a")
        XCTAssertEqual(immediate, models)
        await loads.respond(1, .failure(ModelCatalogError.unavailable(503)))
        let afterFailure = try await cache.models(baseURL: base, key: "key-a")
        XCTAssertEqual(afterFailure, models)
        cache.cancel()

        // Clearing the form when dismissed must not erase the successful cache.
        cache.prefetch(baseURL: "", key: "")
        cache.prefetch(baseURL: base, key: "key-a", debounce: .seconds(60))
        let reopened = try await cache.models(baseURL: base, key: "key-a")
        XCTAssertEqual(reopened, models)
        cache.cancel()
    }

    @MainActor
    func testCatalogChangedCredentialsRejectLateResultsFromOldConnection() async throws {
        let loads = PendingCatalogLoads()
        let cache = ModelCatalogCache { try await loads.load($0, $1) }
        let base = "https://example.test/v1"
        cache.prefetch(baseURL: base, key: "old-key")
        await loads.waitForRequests(1)
        cache.prefetch(baseURL: base, key: "new-key")
        await loads.waitForRequests(2)
        // The loader deliberately ignores cancellation to simulate a late server.
        await loads.respond(0, .success([CatalogModel(id: "wrong-account-model")]))
        let menu = Task { try await cache.models(baseURL: base, key: "new-key") }
        await loads.respond(1, .success([CatalogModel(id: "new-account-model")]))
        let models = try await menu.value
        XCTAssertEqual(models, [CatalogModel(id: "new-account-model")])
        let keys = await loads.keys()
        XCTAssertEqual(keys, ["old-key", "new-key"])
        cache.cancel()
    }

    @MainActor
    func testCatalogTypingDebounceSendsOnlyLatestInputAndMenuFlushesDelay() async throws {
        let loads = PendingCatalogLoads()
        let cache = ModelCatalogCache { try await loads.load($0, $1) }
        let base = "https://example.test/v1"
        cache.prefetch(baseURL: base, key: "part", debounce: .seconds(60))
        cache.prefetch(baseURL: base, key: "complete-key", debounce: .seconds(60))
        let menu = Task { try await cache.models(baseURL: base, key: "complete-key") }
        await loads.waitForRequests(1)
        let keys = await loads.keys()
        XCTAssertEqual(keys, ["complete-key"])
        await loads.respond(0, .success([CatalogModel(id: "latest-model")]))
        let models = try await menu.value
        XCTAssertEqual(models, [CatalogModel(id: "latest-model")])
        cache.cancel()
    }

    @MainActor
    func testCatalogChangedEndpointCannotReuseAnotherProvidersChoices() async throws {
        let loads = PendingCatalogLoads()
        let cache = ModelCatalogCache { try await loads.load($0, $1) }
        let first = "https://first.example.test/v1"
        cache.prefetch(baseURL: first, key: "same-key")
        await loads.waitForRequests(1)
        await loads.respond(0, .success([CatalogModel(id: "first-provider-model")]))
        _ = try await cache.models(baseURL: first, key: "same-key")
        let second = "https://second.example.test/v1"
        cache.prefetch(baseURL: second, key: "same-key")
        await loads.waitForRequests(2)
        let menu = Task { try await cache.models(baseURL: second, key: "same-key") }
        await loads.respond(1, .failure(ModelCatalogError.unavailable(404)))
        do {
            _ = try await menu.value
            XCTFail("A different provider must not receive the old provider's cached choices")
        } catch { XCTAssertTrue(error is ModelCatalogError) }
        cache.cancel()
    }

    private func client(diagnostics: ModelDiagnostics = ModelDiagnostics()) -> ModelClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelURLProtocol.self]
        return ModelClient(session: URLSession(configuration: configuration), diagnostics: diagnostics)
    }

    func testRequestDiagnosticsCorrelatesRateLimitWithoutRecordingCredentialsOrContent() async throws {
        let recorder = DiagnosticRecorder()
        let key = "private-key-for-diagnostics"
        ModelURLProtocol.fixture.configure(
            status: 429, mime: "application/json", headers: ["Retry-After": "12", "x-request-id": "req-429"],
            body:
                #"{"error":{"code":"insufficient_quota","type":"rate_limit_error","message":"private-key-for-diagnostics PRIVATE_QUESTION PRIVATE_DOCUMENT"}}"#
        )
        let connection = ModelConfiguration(
            baseURL: "https://example.test/private-key-for-diagnostics/v1", model: "fixture-model")
        do {
            _ = try await client(diagnostics: ModelDiagnostics(record: recorder.append)).stream(
                configuration: connection, key: key,
                messages: [ChatMessage(role: "user", content: "PRIVATE_QUESTION PRIVATE_DOCUMENT")],
                maxOutputTokens: 2048, context: .init(runID: "run-429"), onText: { _ in })
            XCTFail("The original rate limit must still be reported")
        } catch ModelError.rateLimited(let delay) { XCTAssertEqual(delay, 12) }
        let events = recorder.events()
        XCTAssertEqual(
            events.map(\.name), ["request.start", "request.response", "request.remote_error", "request.end"])
        XCTAssertEqual(Set(events.compactMap(\.requestID)).count, 1)
        XCTAssertTrue(events.allSatisfy { $0.runID == "run-429" && $0.purpose == .answer })
        XCTAssertEqual(events[0].maxOutputTokens, 2048)
        XCTAssertEqual(events[0].model, "fixture-model")
        XCTAssertEqual(events[0].service, "example.test")
        XCTAssertEqual(events[1].httpStatus, 429)
        XCTAssertEqual(events[1].providerRequestID, "req-429")
        XCTAssertEqual(events[1].retryAfterSeconds, 12)
        XCTAssertEqual(events[2].providerCode, "insufficient_quota")
        XCTAssertEqual(events[2].providerType, "rate_limit_error")
        XCTAssertEqual(events[3].outcome, "rateLimit")
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for secret in [key, "PRIVATE_QUESTION", "PRIVATE_DOCUMENT", "message\""] {
            XCTAssertFalse(encoded.contains(secret))
        }
        XCTAssertEqual(ModelURLProtocol.fixture.requestCount(), 1)
    }

    func testRequestDiagnosticsDistinguishesSummaryAndRecordsFirstTextAndUsage() async throws {
        let recorder = DiagnosticRecorder()
        ModelURLProtocol.fixture.configure(
            mime: "application/json",
            body:
                #"{"choices":[{"message":{"content":"PRIVATE_ANSWER"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#
        )
        let model = client(diagnostics: ModelDiagnostics(record: recorder.append))
        for purpose in [ModelDiagnostics.Purpose.answer, .summary] {
            _ = try await model.stream(
                configuration: ModelConfiguration(
                    baseURL: "https://example.test/v1", model: "fixture-model", apiProtocol: .chatCompletions),
                key: "private-diagnostic-key", messages: [ChatMessage(role: "user", content: "PRIVATE_QUESTION")],
                context: .init(runID: "one-run", purpose: purpose), onText: { _ in })
        }
        let events = recorder.events()
        XCTAssertEqual(Set(events.compactMap(\.requestID)).count, 2)
        XCTAssertEqual(events.filter { $0.name == "request.first_text" }.count, 2)
        for purpose in [ModelDiagnostics.Purpose.answer, .summary] {
            let result = events.filter { $0.purpose == purpose }
            XCTAssertEqual(
                result.map(\.name), ["request.start", "request.response", "request.first_text", "request.end"])
            XCTAssertEqual(result.last?.outcome, "completed")
            XCTAssertEqual(result.last?.inputTokens, 12)
            XCTAssertEqual(result.last?.outputTokens, 3)
        }
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains("PRIVATE_ANSWER"))
    }

    private func catalog() -> ModelCatalog {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelURLProtocol.self]
        return ModelCatalog(session: URLSession(configuration: configuration))
    }

    func testModelCatalogUsesAuthenticatedGETAndDeduplicatesProviderIDs() async throws {
        ModelURLProtocol.fixture.configure(
            mime: "application/json",
            body: #"{"data":[{"id":"b","name":"Model B"},{"id":"a"},{"id":"b"},{"id":""},{"id":"   "}]}"#)
        let models = try await catalog().models(baseURL: "https://example.test/v1/responses/", key: "catalog-test-key")
        XCTAssertEqual(models, [CatalogModel(id: "a"), CatalogModel(id: "b", name: "Model B")])
        let request = try XCTUnwrap(ModelURLProtocol.fixture.request())
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer catalog-test-key")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(ModelURLProtocol.fixture.requestCount(), 1)
    }

    func testModelCatalogEndpointDoesNotRequireAModelAndPreservesProviderPrefix() throws {
        for suffix in ["", "/", "/responses", "/chat/completions", "/models"] {
            let configuration = ModelConfiguration(baseURL: "https://example.test/custom/v1" + suffix)
            XCTAssertEqual(try configuration.modelsEndpoint().absoluteString, "https://example.test/custom/v1/models")
            XCTAssertThrowsError(try configuration.endpoint(), "Sending still requires an explicit model")
        }
    }

    func testModelCatalogRejectsUnavailableAndMalformedListsWithoutReturningServerMessages() async {
        for (status, body) in [
            (404, #"{"error":"catalog-test-key"}"#), (200, "<html>Unavailable</html>"), (200, #"{"models":[]}"#),
        ] {
            ModelURLProtocol.fixture.configure(status: status, mime: "application/json", body: body)
            do {
                _ = try await catalog().models(baseURL: "https://example.test/v1", key: "catalog-test-key")
                XCTFail("Expected catalog failure")
            } catch {
                XCTAssertTrue(error is ModelCatalogError)
                XCTAssertFalse(error.localizedDescription.contains("catalog-test-key"))
            }
        }
    }

    func testModelCatalogEmptyListIsValidAndMissingKeyDoesNotSendARequest() async throws {
        ModelURLProtocol.fixture.configure(mime: "application/json", body: #"{"data":[]}"#)
        let models = try await catalog().models(baseURL: "https://example.test/v1", key: "catalog-test-key")
        XCTAssertTrue(models.isEmpty)
        ModelURLProtocol.fixture.configure(body: "")
        do {
            _ = try await catalog().models(baseURL: "https://example.test/v1", key: " ")
            XCTFail("A missing key must not be sent to the provider")
        } catch {}
        XCTAssertEqual(ModelURLProtocol.fixture.requestCount(), 0)
    }

    func testChatToolIdentitySurvivesEmptyAndNullContinuationFields() async throws {
        // Atlas/Qwen actual stream: only the first chunk identifies the call.
        ModelURLProtocol.fixture.configure(
            body: """
                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_read_17","type":"function","function":{"name":"read_document","arguments":""}}]}}]}

                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"","type":"function","function":{"arguments":"{}"}}]}}]}

                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":null,"type":null,"function":{"arguments":""}}]}}]}

                data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

                """)
        let configuration = ModelConfiguration(
            baseURL: "https://example.test/v1", model: "x", apiProtocol: .chatCompletions)
        let turn = try await client().stream(
            configuration: configuration, key: "test-only-key", messages: [],
            tools: AgentDocumentTools.definitions
        ) { _ in }
        XCTAssertEqual(turn.calls, [.init(id: "call_read_17", name: "read_document", arguments: "{}")])
        let replay = try ModelWireFormat.object(
            ModelToolWire.requestBody(
                configuration, messages: [], tools: AgentDocumentTools.definitions,
                exchanges: [.init(turn: turn, outputs: [.init(id: "call_read_17", content: "read result")])]))
        let messages = try XCTUnwrap(replay["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["tool_call_id"] as? String, "call_read_17")
        let calls = messages.first?["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(calls?.first?["id"] as? String, "call_read_17")
        XCTAssertEqual(ModelURLProtocol.fixture.requestCount(), 1)
    }

    func testToolArgumentsAndOpaqueReasoningSurviveBothWireProtocols() async throws {
        let arguments = #"{"revision":"version-1","edits":[{"before":"原文","after":"新文"}]}"#
        func frame(_ value: [String: Any]) throws -> String {
            "data: " + String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n\n"
        }
        for api in ModelAPIProtocol.allCases {
            var events: [[String: Any]]
            if api == .responses {
                let reasoning: [String: Any] = [
                    "type": "reasoning", "id": "rs_1", "summary": [], "encrypted_content": "opaque-signature",
                ]
                let call: [String: Any] = [
                    "type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "edit_document",
                    "arguments": arguments,
                ]
                events = [
                    ["type": "response.output_item.added", "output_index": 0, "item": reasoning],
                    [
                        "type": "response.output_item.added", "output_index": 1,
                        "item": call.merging(["arguments": ""], uniquingKeysWith: { _, b in b }),
                    ],
                    [
                        "type": "response.function_call_arguments.delta", "output_index": 1,
                        "delta": String(arguments.prefix(25)),
                    ],
                    [
                        "type": "response.function_call_arguments.delta", "output_index": 1,
                        "delta": String(arguments.dropFirst(25)),
                    ],
                    ["type": "response.completed", "response": ["status": "completed", "output": [reasoning, call]]],
                ]
            } else {
                events = [
                    [
                        "choices": [
                            [
                                "delta": [
                                    "reasoning_content": "opaque-reasoning",
                                    "tool_calls": [
                                        [
                                            "index": 0, "id": "call_1", "type": "function",
                                            "extra_content": ["provider": ["signature": "opaque-signature"]],
                                            "function": [
                                                "name": "edit_document", "arguments": String(arguments.prefix(25)),
                                            ],
                                        ]
                                    ],
                                ]
                            ]
                        ]
                    ],
                    [
                        "choices": [
                            [
                                "delta": [
                                    "tool_calls": [
                                        ["index": 0, "function": ["arguments": String(arguments.dropFirst(25))]]
                                    ]
                                ]
                            ]
                        ]
                    ],
                    ["choices": [["delta": [:], "finish_reason": "tool_calls"]]],
                ]
            }
            ModelURLProtocol.fixture.configure(body: try events.map(frame).joined())
            let config = ModelConfiguration(baseURL: "https://example.test/v1", model: "tool-model", apiProtocol: api)
            let turn = try await client().stream(
                configuration: config, key: "fixture-key", messages: [.init(role: "user", content: "修改原文")],
                tools: AgentDocumentTools.definitions
            ) { _ in XCTFail("Tool arguments and reasoning are not visible answer text") }
            XCTAssertEqual(turn.calls, [.init(id: "call_1", name: "edit_document", arguments: arguments)])
            let replay = try ModelToolWire.requestBody(
                config, messages: [.init(role: "user", content: "修改原文")],
                tools: AgentDocumentTools.definitions,
                exchanges: [.init(turn: turn, outputs: [.init(id: "call_1", content: #"{"status":"saved"}"#)])])
            let body = try ModelWireFormat.object(replay)
            XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
            let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
            let function = api == .responses ? tools[1] : try XCTUnwrap(tools[1]["function"] as? [String: Any])
            XCTAssertEqual(function["strict"] as? Bool, true)
            XCTAssertEqual(function["name"] as? String, "edit_document")
            let history = try XCTUnwrap(body[api == .responses ? "input" : "messages"] as? [[String: Any]])
            if api == .responses {
                XCTAssertEqual(history[1]["encrypted_content"] as? String, "opaque-signature")
                XCTAssertEqual(history.last?["call_id"] as? String, "call_1")
                XCTAssertEqual(body["store"] as? Bool, false)
                XCTAssertNil(body["previous_response_id"])
            } else {
                XCTAssertEqual(history[1]["reasoning_content"] as? String, "opaque-reasoning")
                XCTAssertTrue(String(decoding: replay, as: UTF8.self).contains("opaque-signature"))
                XCTAssertEqual(history.last?["tool_call_id"] as? String, "call_1")
            }
        }
    }

    func testResponsesCompletedOutputOverridesPartialToolEvents() async throws {
        ModelURLProtocol.fixture.configure(
            body: """
                data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"partial","call_id":"partial","name":"read_document","arguments":"{}"}}

                data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"最终回答。"}]}]}}

                """)
        let turn = try await client().stream(
            configuration: .init(baseURL: "https://example.test/v1", model: "fixture"), key: "fixture-key",
            messages: [], tools: AgentDocumentTools.definitions
        ) { _ in }
        XCTAssertTrue(turn.calls.isEmpty, "A discarded partial tool item must never execute")
        XCTAssertEqual(turn.text, "最终回答。")
        XCTAssertEqual(turn.responseItems.count, 1)
    }

    func testIncompleteToolStreamNeverReturnsAnExecutableCall() async throws {
        let streams: [(ModelAPIProtocol, String)] = [
            (
                .responses,
                #"data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"one","name":"read_document","arguments":"{}"}}"#
                    + "\n\n"
            ),
            (
                .chatCompletions,
                #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"one","type":"function","function":{"name":"read_document","arguments":"{}"}}]},"finish_reason":"length"}]}"#
                    + "\n\n"
            ),
        ]
        for (api, body) in streams {
            ModelURLProtocol.fixture.configure(body: body)
            do {
                _ = try await client().stream(
                    configuration: .init(baseURL: "https://example.test/v1", model: "fixture", apiProtocol: api),
                    key: "fixture-key", messages: [], tools: AgentDocumentTools.definitions
                ) { _ in }
                XCTFail("An incomplete model turn must not expose its tools for execution")
            } catch let error as ModelError {
                switch (api, error) {
                case (.responses, .interrupted), (.chatCompletions, .incomplete): break
                default: XCTFail("Unexpected failure type: \(error)")
                }
            }
            XCTAssertEqual(ModelURLProtocol.fixture.requestCount(), 1)
        }
    }

    func testEndpointValidationIdentifiesTheInvalidField() {
        for (baseURL, model, expected) in [
            ("", "", ModelConfigurationError.missingBaseURL),
            ("", "chosen-model", .missingBaseURL),
            ("not-a-url", "", .invalidBaseURL),
            ("https://example.test/v1", "  ", .missingModel),
        ] {
            XCTAssertThrowsError(try ModelConfiguration(baseURL: baseURL, model: model).endpoint()) { error in
                XCTAssertEqual(error as? ModelConfigurationError, expected)
            }
        }
    }

    func testEndpointValidationAndPathComposition() throws {
        XCTAssertEqual(
            try ModelConfiguration(baseURL: "https://example.test/v1/", model: "x").endpoint().path,
            "/v1/responses")
        XCTAssertEqual(
            try ModelConfiguration(baseURL: "https://example.test/v1/chat/completions/", model: "x").endpoint().path,
            "/v1/responses")
        XCTAssertEqual(
            try ModelConfiguration(
                baseURL: "https://example.test/compatible-mode/v1/responses", model: "x", apiProtocol: .chatCompletions
            ).endpoint().path,
            "/compatible-mode/v1/chat/completions")
        XCTAssertEqual(
            try ModelConfiguration(
                baseURL: "https://example.test/v1/", model: "chosen-model", apiProtocol: .chatCompletions
            ).endpoint()
                .absoluteString, "https://example.test/v1/chat/completions")
        XCTAssertEqual(
            try ModelConfiguration(
                baseURL: "https://example.test/v1/chat/completions", model: "chosen-model",
                apiProtocol: .chatCompletions
            )
            .endpoint().path, "/v1/chat/completions")
        XCTAssertThrowsError(try ModelConfiguration(baseURL: "file:///secret", model: "x").endpoint())
        XCTAssertThrowsError(try ModelConfiguration(baseURL: "https://key@example.test", model: "x").endpoint())
        XCTAssertThrowsError(try ModelConfiguration(baseURL: "https://example.test?api_key=x", model: "x").endpoint())
        XCTAssertThrowsError(try ModelConfiguration(baseURL: "https://example.test", model: "").endpoint())
    }

    func testResponsesStreamUsesStatelessFullHistoryAndTypedTerminalEvent() async throws {
        ModelURLProtocol.fixture.configure(
            body: """
                : keepalive

                event: response.created
                data: {"type":"response.created","response":{"status":"in_progress"}}

                event: response.output_text.delta
                data: {"delta":
                data: "中文回答"}

                data: {"type":"response.reasoning_summary_text.delta","delta":"do not expose reasoning"}

                data: {"type":"response.completed","response":{"status":"completed","output":[]}}

                """.replacingOccurrences(of: "\n", with: "\r\n"))
        let collector = AnswerCollector()
        try await client().stream(
            configuration: .init(baseURL: "https://example.test/v1", model: "x"), key: "test-only-key",
            messages: [
                .init(role: "system", content: "instruction"), .init(role: "user", content: "first"),
                .init(role: "assistant", content: "reply"), .init(role: "user", content: "followup"),
            ]
        ) { await collector.append($0) }
        let text = await collector.text
        XCTAssertEqual(text, "中文回答")
        let request = try XCTUnwrap(ModelURLProtocol.fixture.request())
        XCTAssertEqual(request.url?.path, "/v1/responses")
        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "MarkdownIt/" + version)
        let body = try ModelWireFormat.object(XCTUnwrap(request.httpBody))
        XCTAssertEqual(body["instructions"] as? String, "instruction")
        XCTAssertEqual((body["input"] as? [[String: String]])?.map { $0["role"] }, ["user", "assistant", "user"])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertNil(body["previous_response_id"])
        XCTAssertNil(body["messages"])
        XCTAssertEqual(ModelURLProtocol.fixture.requestCount(), 1)
    }

    func testResponsesJSONReadsOnlyAnswerItems() async throws {
        ModelURLProtocol.fixture.configure(
            mime: "application/json",
            body:
                #"{"status":"completed","output":[{"type":"reasoning","summary":[{"text":"private"}]},{"type":"message","content":[{"type":"output_text","text":"**回答**"}]}]}"#
        )
        let collector = AnswerCollector()
        try await client().stream(
            configuration: .init(baseURL: "https://example.test/v1", model: "x"), key: "test-only-key", messages: []
        ) { await collector.append($0) }
        let text = await collector.text
        XCTAssertEqual(text, "**回答**")
    }

    func testInterruptedAndIncompleteStreamsKeepPartialTextWithoutRetry() async throws {
        for terminal in [
            "", #"data: {"type":"response.failed","response":{"status":"failed"}}"#,
            #"data: {"type":"response.incomplete","response":{"status":"incomplete"}}"#,
        ] {
            ModelURLProtocol.fixture.configure(
                body: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"已收到\"}\n\n" + terminal + "\n\n")
            let collector = AnswerCollector()
            do {
                try await client().stream(
                    configuration: .init(baseURL: "https://example.test/v1", model: "x"), key: "test-only-key",
                    messages: []
                ) { await collector.append($0) }
                XCTFail("A missing or failed completion must not succeed")
            } catch is ModelError {}
            let text = await collector.text
            XCTAssertEqual(text, "已收到")
            XCTAssertEqual(ModelURLProtocol.fixture.requestCount(), 1)
        }
    }

    func testUnsupportedEndpointAndRateLimitNeverProbeOrResend() async throws {
        for status in [404, 429] {
            ModelURLProtocol.fixture.configure(
                status: status, headers: ["Retry-After": "12"], body: #"{"error":{"message":"not supported"}}"#)
            do {
                try await client().stream(
                    configuration: .init(baseURL: "https://example.test/v1", model: "x"), key: "test-only-key",
                    messages: []
                ) { _ in }
                XCTFail("Expected a service error")
            } catch ModelError.rateLimited(let delay) { XCTAssertEqual(delay, 12) } catch ModelError.service(
                let code, _)
            { XCTAssertEqual(code, status) }
            XCTAssertEqual(ModelURLProtocol.fixture.requestCount(), 1)
            XCTAssertEqual(ModelURLProtocol.fixture.request()?.url?.path, "/v1/responses")
        }
    }

    func testTruncatedJSONKeepsAnswerAndContextLimitIsActionable() async throws {
        ModelURLProtocol.fixture.configure(
            mime: "application/json",
            body:
                #"{"status":"incomplete","output":[{"type":"message","content":[{"type":"output_text","text":"尚未完成的回答"}]}]}"#
        )
        let collector = AnswerCollector()
        do {
            try await client().stream(
                configuration: .init(baseURL: "https://example.test/v1", model: "x"), key: "test-only-key", messages: []
            ) { await collector.append($0) }
            XCTFail("An incomplete response must not succeed")
        } catch ModelError.incomplete {}
        let text = await collector.text
        XCTAssertEqual(text, "尚未完成的回答")
        ModelURLProtocol.fixture.configure(
            status: 400, body: #"{"error":{"code":"context_length_exceeded","message":"maximum context exceeded"}}"#)
        do {
            try await client().stream(
                configuration: .init(baseURL: "https://example.test/v1", model: "x"), key: "test-only-key", messages: []
            ) { _ in }
            XCTFail("Expected an explicit context limit error")
        } catch ModelError.contextLimit {}
        XCTAssertEqual(ModelURLProtocol.fixture.requestCount(), 1)
        ModelURLProtocol.fixture.configure(
            status: 400, body: #"{"code":400,"msg":"maximum context exceeded","data":null}"#)
        do {
            try await client().stream(
                configuration: .init(baseURL: "https://example.test/v1", model: "x"), key: "test-only-key", messages: []
            ) { _ in }
            XCTFail("Atlas code/msg must preserve an explicit context-window failure")
        } catch ModelError.contextLimit {}
        ModelURLProtocol.fixture.configure(status: 413, body: #"{"code":413,"msg":"Request body exceeds 50 MB"}"#)
        do {
            try await client().stream(
                configuration: .init(baseURL: "https://example.test/v1", model: "x"), key: "test-only-key", messages: []
            ) { _ in }
            XCTFail("Payload size is not a model token-window error")
        } catch ModelError.requestTooLarge {}
    }

    func testStreamingHandlesRoleUsageAndFragmentedUnicode() async throws {
        ModelURLProtocol.fixture.configure(
            body: """
                data: {"choices":[{"delta":{"role":"assistant","content":""}}]}

                data: {"choices":[{"delta":{"content":"中文"}}]}

                data: {"choices":[{"delta":{"content":"回答"}}]}

                data: {"choices":[],"usage":{"total_tokens":4}}

                data: [DONE]

                """)
        let collector = AnswerCollector()
        try await client().stream(
            configuration: .init(
                baseURL: "https://example.test/v1", model: "chosen-model", apiProtocol: .chatCompletions),
            key: "test-only-key", messages: [.init(role: "user", content: "解释所选文字")]
        ) { await collector.append($0) }
        let answer = await collector.text
        XCTAssertEqual(answer, "中文回答")
        let request = try XCTUnwrap(ModelURLProtocol.fixture.request())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "chosen-model")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("test-only-key"))
    }

    func testJSONFallbackAndRedactedServiceErrors() async throws {
        ModelURLProtocol.fixture.configure(
            mime: "application/json", body: #"{"choices":[{"message":{"content":"完整回答"}}]}"#)
        let collector = AnswerCollector()
        try await client().stream(
            configuration: .init(
                baseURL: "https://example.test/v1", model: "chosen-model", apiProtocol: .chatCompletions),
            key: "test-only-key",
            messages: []
        ) { await collector.append($0) }
        let answer = await collector.text
        XCTAssertEqual(answer, "完整回答")
        ModelURLProtocol.fixture.configure(
            status: 401, mime: "application/json", body: #"{"error":{"message":"Invalid test-only-key"}}"#)
        do {
            try await client().stream(
                configuration: .init(
                    baseURL: "https://example.test/v1", model: "chosen-model", apiProtocol: .chatCompletions),
                key: "test-only-key",
                messages: []
            ) { _ in }
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains("test-only-key"))
        }
    }

    func testOutputBudgetAndUsageAreConsistentAcrossProtocolsAndResponseFormats() async throws {
        for api in ModelAPIProtocol.allCases {
            let root: [String: Any] =
                api == .responses
                ? [
                    "status": "completed",
                    "output": [["type": "message", "content": [["type": "output_text", "text": "OK"]]]],
                    "usage": ["input_tokens": 123, "output_tokens": 7],
                ]
                : [
                    "choices": [["message": ["content": "OK"], "finish_reason": "stop"]],
                    "usage": ["prompt_tokens": 123, "completion_tokens": 7],
                ]
            for streaming in [false, true] {
                var payload = root
                if streaming {
                    if api == .responses {
                        payload = ["type": "response.completed", "response": root]
                    } else {
                        payload["choices"] = [["delta": ["content": "OK"], "finish_reason": "stop"]]
                    }
                }
                let data = try JSONSerialization.data(withJSONObject: payload)
                let body =
                    streaming
                    ? "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
                    : String(decoding: data, as: UTF8.self)
                for tools in [[], [AgentDocumentTools.definitions[0]]] {
                    ModelURLProtocol.fixture.configure(
                        mime: streaming ? "text/event-stream" : "application/json", body: body)
                    let turn = try await client().stream(
                        configuration: .init(
                            baseURL: "https://example.test/v1", model: "chosen-model", apiProtocol: api),
                        key: "test-only-key", messages: [.init(role: "user", content: "Hello")],
                        tools: tools, maxOutputTokens: 6144
                    ) { _ in }
                    XCTAssertEqual(turn.text, "OK")
                    XCTAssertEqual(turn.usage?.inputTokens, 123)
                    XCTAssertEqual(turn.usage?.outputTokens, 7)
                    let request = try XCTUnwrap(ModelURLProtocol.fixture.request()?.httpBody)
                    let object = try ModelWireFormat.object(request)
                    XCTAssertEqual(
                        object[api == .responses ? "max_output_tokens" : "max_completion_tokens"] as? Int, 6144)
                    if api == .responses { XCTAssertEqual(object["store"] as? Bool, false) }
                }
            }
        }
    }

    func testCatalogDecodesIndependentContextAndGenerationLimits() throws {
        let data = Data(
            #"[{"id":"large","context_length":1000000,"max_output_tokens":64000},{"id":"small","context_window":32000,"max_completion_tokens":4000},{"id":"unknown","max_output_tokens":-1}]"#
                .utf8)
        let models = try JSONDecoder().decode([CatalogModel].self, from: data)
        XCTAssertEqual(models[0].contextWindow, 1_000_000)
        XCTAssertEqual(models[0].maxOutputTokens, 64_000)
        XCTAssertEqual(models[1].maxOutputTokens, 4000)
        XCTAssertNil(models[2].contextWindow)
        XCTAssertNil(models[2].maxOutputTokens)
    }

    func testAtlasClaudeDeepSeekAndQwenCatalogLimitsKeepTheirSeparateMeanings() throws {
        let json =
            #"[{"id":"atlas","context_length":1050000,"max_output_length":131072},{"id":"claude","display_name":"Claude","max_input_tokens":1000000,"max_tokens":128000},{"id":"deepseek","context_window":1048576,"max_output_tokens":393216},{"model":"qwen","model_info":{"context_window":1000000,"max_input_tokens":983616,"max_output_tokens":65536}},{"id":"unknown","context_length":null,"max_output_length":true}]"#
        let models = try JSONDecoder().decode([CatalogModel].self, from: Data(json.utf8))
        XCTAssertEqual(models[0].capabilities, .init(contextWindow: 1_050_000, maxOutputTokens: 131_072))
        XCTAssertEqual(models[1].capabilities, .init(maxInputTokens: 1_000_000, maxOutputTokens: 128_000))
        XCTAssertNil(models[1].contextWindow, "An input-only limit must not become a total window")
        XCTAssertEqual(models[2].capabilities, .init(contextWindow: 1_048_576, maxOutputTokens: 393_216))
        XCTAssertEqual(
            models[3].capabilities, .init(contextWindow: 1_000_000, maxInputTokens: 983_616, maxOutputTokens: 65_536))
        XCTAssertEqual(models[4].capabilities, .init())
    }

    func testBundledCatalogMatchesTheExactServiceAndModelWithoutGuessingFromNames() throws {
        let catalog = try XCTUnwrap(BundledModelCatalog.shared)
        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertEqual(catalog.revision.count, 40)
        let configuration = ModelConfiguration(
            baseURL: "https://API.OPENAI.COM:443/v1/responses/", model: "gpt-6.1-sol")
        let limits = catalog.capabilities(for: configuration)
        XCTAssertEqual(limits.contextWindow, 1_050_000)
        XCTAssertEqual(limits.maxOutputTokens, 128_000)
        XCTAssertEqual(limits.maxInputTokens, 922_000)
        for url in ["https://proxy.example/v1", "http://api.openai.com/v1", "https://api.openai.com/other/v1"] {
            XCTAssertEqual(catalog.capabilities(for: .init(baseURL: url, model: configuration.model)), .init())
        }
        XCTAssertEqual(
            catalog.capabilities(for: .init(baseURL: configuration.baseURL, model: "gpt-new-unknown")), .init())
        let remote = ModelCapabilities(contextWindow: 200_000, maxOutputTokens: 32_000)
        XCTAssertEqual(
            remote.fillingMissing(from: limits),
            .init(contextWindow: 200_000, maxInputTokens: 922_000, maxOutputTokens: 32_000))
    }

    func testProviderCatalogPaginationAndHeadersStayOnTheConfiguredService() async throws {
        ModelURLProtocol.fixture.configure(
            mime: "application/json", body: "",
            pages: [
                #"{"output":{"total":2,"models":[{"model":"first","model_info":{"context_window":1000000}}]}}"#,
                #"{"output":{"total":2,"models":[{"model":"last","model_info":{"max_output_tokens":65536}}]}}"#,
            ])
        let qwen = try await catalog().models(
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", key: "test-only-key")
        XCTAssertEqual(qwen.count, 2)
        XCTAssertEqual(ModelURLProtocol.fixture.requestCount(), 2)
        XCTAssertEqual(ModelURLProtocol.fixture.request()?.url?.path, "/api/v1/models")
        XCTAssertEqual(ModelURLProtocol.fixture.request()?.url?.query, "page_no=2")
        ModelURLProtocol.fixture.configure(
            mime: "application/json", body: "",
            pages: [
                #"{"data":[{"id":"first","max_input_tokens":1000000}],"has_more":true,"last_id":"first"}"#,
                #"{"data":[{"id":"last","max_tokens":128000}],"has_more":false,"last_id":"last"}"#,
            ])
        let claude = try await catalog().models(baseURL: "https://api.anthropic.com/v1", key: "test-only-key")
        XCTAssertEqual(claude.count, 2)
        XCTAssertEqual(ModelURLProtocol.fixture.request()?.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(ModelURLProtocol.fixture.request()?.url?.query, "after_id=first")
    }

    func testUnknownOutputLimitsAreOmittedAndKnownChatLimitsUseTheProvidersField() throws {
        for api in ModelAPIProtocol.allCases {
            for tools in [[], [AgentDocumentTools.definitions[0]]] {
                for base in [
                    "https://example.test/v1", "https://api.deepseek.com",
                    "https://dashscope.aliyuncs.com/compatible-mode/v1",
                ] {
                    let configuration = ModelConfiguration(baseURL: base, model: "fixture", apiProtocol: api)
                    func body(_ limit: Int?) throws -> [String: Any] {
                        let data =
                            try tools.isEmpty
                            ? ModelWireFormat.requestBody(configuration, messages: [], maxOutputTokens: limit)
                            : ModelToolWire.requestBody(
                                configuration, messages: [], tools: tools, exchanges: [], maxOutputTokens: limit)
                        return try ModelWireFormat.object(data)
                    }
                    let unknown = try body(nil)
                    for key in ["max_tokens", "max_output_tokens", "max_completion_tokens"] {
                        XCTAssertNil(unknown[key])
                    }
                    let known = try body(131_072)
                    let field =
                        api == .responses
                        ? "max_output_tokens" : base.contains("example.test") ? "max_completion_tokens" : "max_tokens"
                    XCTAssertEqual(known[field] as? Int, 131_072)
                }
            }
        }
    }

    func testContextErrorsRequireAnExplicitSignalAndDoNotConfuseOtherLimits() {
        for value: [String: Any] in [
            ["code": "context_length_exceeded"],
            ["type": "invalid_request_error", "message": "prompt is too long"],
            ["message": "Range of input length should be [1, 1000000]"],
        ] {
            guard case .contextLimit = ModelWireFormat.remoteError(value, fallback: .generationFailed) else {
                return XCTFail("An explicit input overflow must be recognized")
            }
        }
        for message in [
            "Range of max_tokens should be [1, 65536]", "context window parameter is invalid",
            "Too many tokens per minute", "request body exceeds 50 MB",
        ] {
            if case .contextLimit = ModelWireFormat.remoteError(["message": message], fallback: .generationFailed) {
                XCTFail("Unrelated errors cannot trigger compaction: \(message)")
            }
        }
    }

    @MainActor
    func testContextRejectionsDoNotRetryOrInventPersistedCapacities() async throws {
        for localFailure in [true, false] {
            ModelURLProtocol.fixture.configure(
                status: 400, mime: "application/json",
                body: #"{"error":{"code":"context_length_exceeded","message":"maximum context exceeded"}}"#)
            let question = localFailure ? String(repeating: "问题", count: 10_000) : "Explain."
            let snapshot = AgentSnapshot(
                question: question, attachment: nil,
                history: [.init(role: "user", markdown: question, attachment: nil)])
            let budget = AgentContextBudget(capabilities: .init(contextWindow: 32_768))
            let input = try AgentContextBuilder.build(snapshot, intent: "question")
            XCTAssertEqual(
                budget.fits(budget.cost(input, tools: [AgentDocumentTools.definitions[0]])), !localFailure,
                "The fixture must distinguish local overflow from a request rejected by the service")
            let transport = AgentModelTransport(client: client())
            var failure: AgentFailure?
            transport.start(
                id: UUID().uuidString, token: "context-limit", snapshot: snapshot, intent: "question",
                configuration: .init(baseURL: "https://example.test/v1", model: "fixture"),
                key: "test-only-key", capabilities: { .init(contextWindow: 32_768) },
                emit: { event in
                    if event.type == "failure" { failure = event.failure }
                })
            let deadline = Date().addingTimeInterval(10)
            while failure == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(failure?.kind, "contextLimit")
            XCTAssertEqual(ModelURLProtocol.fixture.requestCount(), localFailure ? 0 : 1)
            let state = try XCTUnwrap(transport.recovery()?.context)
            let persisted = try ModelWireFormat.object(JSONEncoder().encode(state))
            XCTAssertNil(persisted["learnedWindow"])
            XCTAssertNil(persisted["contextWindow"])
            transport.cancel()
        }
    }
}
