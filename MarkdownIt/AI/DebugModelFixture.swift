#if DEBUG
    import Foundation

    /// Deterministic responses for UI screenshots. Excluded from Release builds;
    /// enabled only by the isolated UI-test launch argument, never by settings.
    final class DebugModelFixture: URLProtocol, @unchecked Sendable {
        static func client() -> ModelClient {
            ModelClient(session: session())
        }

        static func catalog() -> ModelCatalog {
            ModelCatalog(session: session())
        }

        static func searchClient() -> WebSearchClient {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DebugSearchFixture.self]
            return WebSearchClient(session: URLSession(configuration: configuration))
        }

        private static func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DebugModelFixture.self]
            return URLSession(configuration: configuration)
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "ui-fixture.markdownit.invalid"
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            if request.httpMethod == "GET", request.url?.path.hasSuffix("/models") == true {
                // Remains pending until URLSession cancellation/timeout, so UI
                // tests can exercise custom entry during an in-flight catalog.
                if request.url?.path.contains("/slow/") == true { return }
                let status = request.url?.path.contains("/unavailable/") == true ? 404 : 200
                let models =
                    [
                        ["id": "ui-test-model", "name": "Current Model"],
                        ["id": "catalog-only-model", "name": "Catalog Choice"],
                        ["id": "provider/advanced-model", "name": "Advanced Reader"],
                        ["id": "openai/gpt-6.1-sol"],
                        ["id": "provider/compact-name", "name": "GPT 6.1 Sol Codex"],
                    ] + (0..<121).map { ["id": "provider/test-\($0)", "name": "Reference \($0)"] }
                let data = (try? JSONSerialization.data(withJSONObject: ["data": models])) ?? Data()
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            do {
                let body = try ModelWireFormat.object(Self.body(request))
                let input = (body["input"] as? [[String: Any]]) ?? []
                let raw = input.last(where: { $0["role"] as? String == "user" })?["content"] as? String ?? "{}"
                let context = try ModelWireFormat.object(Data(raw.utf8))
                let question = context["request"] as? String ?? ""
                let outputs = input.filter { $0["type"] as? String == "function_call_output" }
                var text = ""
                var call: [String: Any]?
                if question.contains("SEARCH_PUBLIC_REFERENCE") {
                    let canSearch = (body["tools"] as? [[String: Any]] ?? []).contains { tool in
                        tool["name"] as? String == "web_search"
                    }
                    if !outputs.isEmpty {
                        let textOutput = String(describing: outputs.last!)
                        text =
                            textOutput.contains("search_permission")
                            ? "Continue using the document without web search."
                            : "See the [Markdown reference](https://commonmark.org/help/) for the original explanation."
                    } else if canSearch {
                        let arguments = #"{"query":"Markdown reference","language":"en"}"#
                        call = [
                            "type": "function_call", "id": "fc_ui_search", "call_id": "call_ui_search",
                            "name": "web_search", "arguments": arguments,
                        ]
                    } else {
                        text = "Web search is not enabled. You can configure it in Model Settings."
                    }
                } else if !outputs.isEmpty {
                    text = "已修改这句话，其余内容保持原样。"
                } else if question.contains("修改") || question.contains("改成") {
                    let canEdit = (body["tools"] as? [[String: Any]] ?? []).contains { tool in
                        tool["name"] as? String == "edit_document"
                    }
                    if !canEdit {
                        text = "请切换到源码模式后再修改。"
                    } else {
                        let background = context["background"] as? [String: Any] ?? [:]
                        let currentID = background["currentDocumentID"] as? String
                        let document =
                            (background["documents"] as? [[String: Any]] ?? []).first {
                                $0["id"] as? String == currentID
                            } ?? [:]
                        let before = "这是一份可以实际滚动、选择、修改和来回切换的长文样例。"
                        let arguments: [String: Any] = [
                            "revision": document["revision"] as? String ?? "",
                            "edits": [["before": before, "after": "这是一份清晰易读的 Markdown 文档。"]],
                        ]
                        let encoded = String(
                            decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
                        call = [
                            "type": "function_call", "id": "fc_ui_edit", "call_id": "call_ui_edit",
                            "name": "edit_document", "arguments": encoded,
                        ]
                    }
                } else {
                    text =
                        "这份文档演示了 **Markdown 的结构与排版**。\n\n标题组织内容，列表表达层次，代码、表格和图表补充说明。预览与源码来自同一份文本。\n\n| 内容 | 阅读方式 |\n| --- | --- |\n| 标题 | 通过目录导航 |\n| 代码与公式 | 保留原有格式 |"
                }
                let payload: [String: Any]
                let output =
                    call.map { [$0] } ?? [
                        [
                            "type": "message", "role": "assistant",
                            "content": [["type": "output_text", "text": text]],
                        ]
                    ]
                payload = ["status": "completed", "output": output]
                let data = try JSONSerialization.data(withJSONObject: payload)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }

        private static func body(_ request: URLRequest) throws -> Data {
            if let data = request.httpBody { return data }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            return data
        }
    }

    private final class DebugSearchFixture: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool {
            WebSearchProvider.allCases.contains { $0.endpoint.host == request.url?.host }
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            let item: [String: String] = [
                "title": "Markdown reference", "url": "https://commonmark.org/help/",
                "link": "https://commonmark.org/help/",
                "snippet": "Search fixture result.", "content": "Search fixture result.",
                "description": "Search fixture result.",
            ]
            let provider = WebSearchProvider.allCases.first { $0.endpoint.host == request.url?.host }
            let root: [String: Any] =
                switch provider {
                case .serper: ["organic": [item]]
                case .tavily: ["results": [item]]
                case .brave: ["web": ["results": [item]]]
                case nil: [:]
                }
            let data = try! JSONSerialization.data(withJSONObject: root)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
#endif
