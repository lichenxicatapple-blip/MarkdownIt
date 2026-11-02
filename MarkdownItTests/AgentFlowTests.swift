import UIKit
import WebKit
import XCTest

@testable import MarkdownIt

private struct AgentFixture: Sendable {
    var status = 200
    var text = ""
    var delay: TimeInterval = 0
    var waitsForCancellation = false
    var waitsAfterText = false
    var complete = true
    var headers: [String: String] = [:]
    var calls: [ModelToolCall] = []
}

private final class AgentFixtureQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [AgentFixture] = []
    private var bodies: [Data] = []
    private var summaryFixture: AgentFixture?
    func reset(_ values: [AgentFixture], summary: AgentFixture? = nil) {
        lock.withLock {
            fixtures = values
            bodies = []
            summaryFixture = summary
        }
    }
    func next(_ request: URLRequest) -> AgentFixture {
        lock.withLock {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let length = stream.read(&buffer, maxLength: buffer.count)
                    guard length > 0 else { break }
                    body.append(contentsOf: buffer.prefix(length))
                }
            }
            bodies.append(body)
            if let summaryFixture,
                let root = try? ModelWireFormat.object(body)
            {
                let instructions =
                    root["instructions"] as? String
                    ?? (root["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
                if instructions.hasPrefix("你只负责压缩对话材料") { return summaryFixture }
            }
            return fixtures.isEmpty ? AgentFixture(status: 503) : fixtures.removeFirst()
        }
    }
    func requests() -> [Data] { lock.withLock { bodies } }
}

private final class AgentFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let queue = AgentFixtureQueue()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "agent.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var fixture = Self.queue.next(request)
        if fixture.calls.contains(where: { $0.arguments == "$first-image" }) {
            let body = Self.queue.requests().last ?? Data()
            let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let items = (payload["input"] ?? payload["messages"]) as? [[String: Any]] ?? []
            let content = items.last?["content"] as? String ?? "{}"
            let user = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any] ?? [:]
            let images = (user["background"] as? [String: Any])?["images"] as? [[String: Any]] ?? []
            let id = images.first?["id"] as? String ?? "missing-inventory"
            fixture.calls = fixture.calls.map {
                ModelToolCall(id: $0.id, name: $0.name, arguments: "{\"imageID\":\"\(id)\"}")
            }
        }
        if fixture.waitsForCancellation { return }
        let responseFixture = fixture
        DispatchQueue.global().asyncAfter(deadline: .now() + responseFixture.delay) {
            [self, fixture = responseFixture] in
            guard !lock.withLock({ stopped }) else { return }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1",
                headerFields: fixture.headers.merging(
                    ["Content-Type": "text/event-stream"], uniquingKeysWith: { a, _ in a }))!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if fixture.status == 200 {
                let responses = request.url?.path.hasSuffix("/responses") == true
                if !fixture.calls.isEmpty {
                    let calls = fixture.calls.map { call -> [String: Any] in
                        responses
                            ? [
                                "type": "function_call", "id": "fc_" + call.id, "call_id": call.id, "name": call.name,
                                "arguments": call.arguments,
                            ]
                            : [
                                "id": call.id, "type": "function",
                                "function": ["name": call.name, "arguments": call.arguments],
                            ]
                    }
                    let payload: [String: Any] =
                        responses
                        ? ["type": "response.completed", "response": ["status": "completed", "output": calls]]
                        : [
                            "choices": [
                                [
                                    "delta": [
                                        "tool_calls": calls.enumerated().map {
                                            $0.element.merging(["index": $0.offset], uniquingKeysWith: { a, _ in a })
                                        }
                                    ], "finish_reason": fixture.complete ? "tool_calls" : "length",
                                ]
                            ]
                        ]
                    let data = try! JSONSerialization.data(withJSONObject: payload)
                    client?.urlProtocol(self, didLoad: Data("data: ".utf8) + data + Data("\n\n".utf8))
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                let payload: [String: Any] =
                    responses
                    ? ["type": "response.output_text.delta", "delta": fixture.text]
                    : ["choices": [["delta": ["content": fixture.text]]]]
                let json = try! JSONSerialization.data(withJSONObject: payload)
                var data = Data("data: ".utf8)
                data.append(json)
                data.append(Data("\n\n".utf8))
                if fixture.complete {
                    data.append(
                        Data(
                            (responses
                                ? "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n"
                                : "data: [DONE]\n\n").utf8))
                }
                client?.urlProtocol(self, didLoad: data)
                if fixture.waitsAfterText { return }
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

@MainActor
final class AgentFlowTests: AgentReaderTestCase {
    func testClosingConversationWaitsForItsPresentationToFinish() async throws {
        let (session, bridge, _, _) = try await reader("# Document\n\nContent.\n")
        _ = try await bridge.call("toggleAgent")
        try await wait { session.agentOpen }
        let acknowledged = await session.closeAgent()
        XCTAssertTrue(acknowledged)
        let closed = try await bridge.webView.evaluateJavaScript(
            "(() => { const p = document.querySelector('.mdv-agent'); return p.hidden && p.inert && !p.hasAttribute('aria-modal') && p.getAnimations().length === 0; })()"
        )
        XCTAssertEqual(closed as? Bool, true, "Closing must acknowledge the completed presentation, not its start")
        XCTAssertFalse(session.agentModalActive)
    }

    func testReopeningConversationCancelsPendingCloseAcknowledgement() async throws {
        let (session, bridge, _, _) = try await reader("# Document\n\nContent.\n")
        _ = try await bridge.call("toggleAgent")
        try await wait { session.agentOpen }
        let acknowledged = try await bridge.webView.callAsyncJavaScript(
            "const closing = window.MarkdownIt.closeAgent(); window.MarkdownIt.toggleAgent(); return await closing;",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(acknowledged as? Bool, false)
        try await wait { session.agentOpen }
        let closed = try await bridge.call("closeAgent")
        let alreadyClosed = try await bridge.call("closeAgent")
        XCTAssertEqual(closed as? Bool, true)
        XCTAssertEqual(alreadyClosed as? Bool, true)
    }

    func testLongConversationCompactsWithoutDeletingVisibleRepliesAndReusesSummary() async throws {
        for api in ModelAPIProtocol.allCases {
            let earlier =
                String(repeating: "Earlier answer with supporting details. ", count: 2100) + "END_OF_EARLIER_REPLY"
            AgentFixtureProtocol.queue.reset(
                [
                    AgentFixture(text: earlier), AgentFixture(text: "The follow-up uses the earlier context."),
                    AgentFixture(text: "Still continuing."),
                ],
                summary: AgentFixture(
                    text: "The user asked about the document. The earlier answer discussed its contents."))
            let (session, bridge, _, _) = try await reader("# Document\n\nCurrent content.\n", api: api)
            _ = try await bridge.call("toggleAgent")
            try await send("Explain the document.", bridge: bridge)
            try await completed(bridge)
            await session.closeAgent()
            try await wait { !session.agentModalActive }
            _ = try await bridge.call("toggleAgent")
            try await send("Follow up on the earlier answer.", bridge: bridge)
            try await completed(bridge, count: 4)
            let requests = AgentFixtureProtocol.queue.requests()
            XCTAssertGreaterThan(requests.count, 2, "Long histories need separate summary requests")
            let final = try ModelWireFormat.object(XCTUnwrap(requests.last))
            let messages = try XCTUnwrap(final[api == .responses ? "input" : "messages"] as? [[String: Any]])
            XCTAssertTrue(messages.contains { ($0["content"] as? String)?.contains("conversationSummary") == true })
            XCTAssertFalse(String(decoding: requests.last!, as: UTF8.self).contains("END_OF_EARLIER_REPLY"))
            let visible = try await state(bridge)["turns"] as? [[String: Any]]
            let reply = try XCTUnwrap(visible?[1]["text"] as? String)
            XCTAssertTrue(reply.contains("END_OF_EARLIER_REPLY"))
            XCTAssertGreaterThanOrEqual(reply.count, earlier.count - 1)
            try await send("One more follow-up.", bridge: bridge)
            try await completed(bridge, count: 6)
            XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, requests.count + 1)
            XCTAssertEqual(session.document?.text, "# Document\n\nCurrent content.\n")
        }
    }

    func testLongDocumentCanBeReadInPreviewWithoutGrantingEditPermission() async throws {
        for api in ModelAPIProtocol.allCases {
            let text =
                "# Long document\n\n" + String(repeating: "Background information.\n\n", count: 4000)
                + "EXACT_END_TARGET\n"
            let call = ModelToolCall(
                id: "read-last-part", name: "read_document",
                arguments: #"{"documentID":null,"offset":null,"query":"EXACT_END_TARGET"}"#)
            AgentFixtureProtocol.queue.reset([
                AgentFixture(calls: [call]), AgentFixture(text: "The ending says EXACT_END_TARGET."),
            ])
            let (session, bridge, _, _) = try await reader(text, api: api)
            _ = try await bridge.call("toggleAgent")
            try await send("What does the ending say?", bridge: bridge)
            try await completed(bridge)
            let requests = AgentFixtureProtocol.queue.requests()
            XCTAssertEqual(requests.count, 2)
            let initial = try ModelWireFormat.object(requests[0])
            let tools = try XCTUnwrap(initial["tools"] as? [[String: Any]])
            let names = tools.compactMap {
                api == .responses ? $0["name"] as? String : ($0["function"] as? [String: Any])?["name"] as? String
            }
            XCTAssertEqual(names, ["read_document"])
            XCTAssertLessThan(requests[0].count, 20_000)
            let continuation = String(decoding: requests[1], as: UTF8.self)
            XCTAssertTrue(continuation.contains("EXACT_END_TARGET"))
            XCTAssertTrue(continuation.contains("precedingContentOmitted"))
            XCTAssertEqual(session.mode, "preview")
            XCTAssertEqual(session.document?.text, text)
        }
    }

    private func reader(
        _ text: String, api: ModelAPIProtocol = .chatCompletions,
        baseURL: String = "https://agent.example.test/v1", model: String = "fixture-model",
        modelKey: @escaping @MainActor () -> String = { "fixture-key" }, dataSharingAllowed: Bool = true
    ) async throws -> (ReaderSession, ReaderBridge, UIWindow, URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentFixtureProtocol.self]
        return try await makeReader(
            text, api: api, baseURL: baseURL, model: model,
            modelClient: ModelClient(session: URLSession(configuration: configuration)),
            modelKey: modelKey, dataSharingAllowed: dataSharingAllowed)
    }

    private func completed(_ bridge: ReaderBridge, count: Int = 2, timeout: TimeInterval = 30) async throws {
        try await wait(timeout: timeout) {
            let status = try await self.state(bridge)
            return (status["turns"] as? [[String: Any]])?.count == count
                && (status["turns"] as? [[String: Any]])?.last?["state"] as? String == "complete"
        }
    }

    func testFirstSendWaitsForConsentAndCancelPreservesDraftAndSelection() async throws {
        AgentFixtureProtocol.queue.reset([AgentFixture(text: "第一轮回答。"), AgentFixture(text: "第二轮回答。")])
        let (session, bridge, _, _) = try await reader(
            "# 文档\n\nSELECTED_ONLY\n\n完整文档背景。\n", dataSharingAllowed: false)
        try await sourceMode(bridge)
        try selectSource("SELECTED_ONLY", bridge: bridge)
        _ = try await bridge.call("askSelection")
        try await send("解释这段。", bridge: bridge)
        try await wait { session.needsDataSharingConsent }
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
        var result = try await state(bridge)
        XCTAssertEqual(result["draft"] as? String, "解释这段。")
        XCTAssertTrue((result["reference"] as? String)?.contains("SELECTED_ONLY") == true)
        XCTAssertEqual((result["turns"] as? [[String: Any]])?.count, 0)
        // A second submission while the native alert is open cannot queue a send.
        try await send("解释这段。", bridge: bridge)
        session.finishDataSharingConsent(allowed: false)
        try await wait {
            try await bridge.webView.evaluateJavaScript("!document.querySelector('.mdv-agent-send').disabled") as? Bool
                == true
        }
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
        result = try await state(bridge)
        XCTAssertEqual(result["draft"] as? String, "解释这段。")
        XCTAssertTrue((result["reference"] as? String)?.contains("SELECTED_ONLY") == true)
        try await send("解释这段。", bridge: bridge)
        try await wait { session.needsDataSharingConsent }
        session.finishDataSharingConsent(allowed: true)
        try await completed(bridge)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 1)
        XCTAssertTrue(String(decoding: AgentFixtureProtocol.queue.requests()[0], as: UTF8.self).contains("完整文档背景"))
        try await send("继续。", bridge: bridge)
        try await completed(bridge, count: 4)
        XCTAssertFalse(session.needsDataSharingConsent)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 2)
    }

    func testConsentCannotAuthorizeAChangedServiceOrAnotherDocument() async throws {
        AgentFixtureProtocol.queue.reset([])
        let (session, bridge, _, file) = try await reader("# 原文\n", dataSharingAllowed: false)
        let originalService = try ModelDataConsent.service(for: session.configuration)
        _ = try await bridge.call("toggleAgent")
        try await send("待发送的问题。", bridge: bridge)
        try await wait { session.needsDataSharingConsent }
        session.configuration.baseURL = "https://agent.example.test/another/v1"
        session.finishDataSharingConsent(allowed: true)
        try await wait {
            try await bridge.webView.evaluateJavaScript("!document.querySelector('.mdv-agent-send').disabled") as? Bool
                == true
        }
        XCTAssertFalse(session.dataConsent.allows(originalService))
        XCTAssertFalse(try session.dataConsent.allows(ModelDataConsent.service(for: session.configuration)))
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
        try await send("待发送的问题。", bridge: bridge)
        try await wait { session.needsDataSharingConsent }
        let next = file.deletingLastPathComponent().appendingPathComponent("another.md")
        try Data("# 另一份文档\n".utf8).write(to: next)
        await session.open(next)
        // This harness hosts WebKit directly rather than SwiftUI's observed
        // ReaderWebView, so forward the document update explicitly.
        bridge.update()
        session.finishDataSharingConsent(allowed: true)
        try await wait { session.rendererReady }
        XCTAssertFalse(session.needsDataSharingConsent)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
        XCTAssertFalse(try session.dataConsent.allows(ModelDataConsent.service(for: session.configuration)))

        // The native request boundary also rejects a snapshot that skipped the UI gate.
        session.requestAgent(
            id: "without-permission", token: session.documentToken,
            snapshot: AgentSnapshot(question: "禁止发送", attachment: nil, history: []), intent: "question")
        XCTAssertNil(session.agentTransport.activeID)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
    }

    func testRetryToAnotherServiceRequiresConsentAndPreservesReplyAndDraft() async throws {
        AgentFixtureProtocol.queue.reset([
            AgentFixture(text: "已经收到的部分回答。", complete: false), AgentFixture(text: "重新生成的回答。"),
        ])
        let (session, bridge, _, _) = try await reader("# 文档\n\n原始全文。\n")
        _ = try await bridge.call("toggleAgent")
        try await send("解释。", bridge: bridge)
        try await wait {
            (try await self.state(bridge)["turns"] as? [[String: Any]])?.last?["state"] as? String == "failed"
        }
        session.configuration.baseURL = "https://agent.example.test/another/v1"
        _ = try await bridge.webView.evaluateJavaScript(
            "const input = document.querySelector('.mdv-composer textarea'); input.value = '下一轮草稿'; input.dispatchEvent(new Event('input', {bubbles:true})); document.querySelector('[data-agent-action=retry]').click();"
        )
        try await wait { session.needsDataSharingConsent }
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 1)
        session.finishDataSharingConsent(allowed: false)
        try await wait {
            try await bridge.webView.evaluateJavaScript("!document.querySelector('.mdv-agent-send').disabled") as? Bool
                == true
        }
        let cancelled = try await state(bridge)
        XCTAssertEqual(cancelled["draft"] as? String, "下一轮草稿")
        XCTAssertTrue(((cancelled["turns"] as? [[String: Any]])?.last?["text"] as? String)?.contains("部分回答") == true)
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('[data-agent-action=retry]').click();")
        try await wait { session.needsDataSharingConsent }
        session.finishDataSharingConsent(allowed: true)
        try await completed(bridge)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 2)
        let completedState = try await state(bridge)
        XCTAssertEqual(completedState["draft"] as? String, "下一轮草稿")
    }

    func testRichRepliesHistoryAndGlobalContextUseCurrentBuffer() async throws {
        let original = "# 原始文档\n\n需要解释的 **概念**。\n\n#### 4.3.2 头部裁剪\n"
        let rich = """
            **回答**与 `code`。

            [章节链接](#432-头部裁剪)

            | 项目 | 内容 |
            | --- | --- |
            | A | B |

            行内公式 $x^2$ 与脚注[^a]。

            ```mermaid
            flowchart LR
              A --> B
            ```

            #### 4.3.2 头部裁剪

            [^a]: 引用说明。
            """
        AgentFixtureProtocol.queue.reset([AgentFixture(text: rich), AgentFixture(text: "第二轮**回答**。")])
        let (session, bridge, _, _) = try await reader(original)
        _ = try await bridge.call("toggleAgent")
        try await wait { session.agentOpen }
        try await send("解释 **概念**。", bridge: bridge)
        try await completed(bridge)
        try await wait {
            try await bridge.webView.evaluateJavaScript(
                "document.querySelectorAll('.mdv-assistant-turn .katex').length === 1 && document.querySelectorAll('.mdv-assistant-turn .mdv-mermaid svg').length === 1"
            ) as? Bool == true
        }
        let first = try await state(bridge)
        XCTAssertEqual((first["turns"] as? [[String: Any]])?.count, 2)
        let unsafe =
            try await bridge.webView.evaluateJavaScript(
                "document.querySelectorAll('.mdv-turn script,.mdv-turn iframe,.mdv-turn [onerror]').length") as? Int
        XCTAssertEqual(unsafe, 0)
        let localLinks =
            try await bridge.webView.evaluateJavaScript(
                """
                (() => {
                  const reply = document.querySelector('.mdv-assistant-turn');
                  return [...reply.querySelectorAll('a[href^="#"]')].every(link => {
                    const target = document.getElementById(decodeURIComponent(link.getAttribute('href').slice(1)));
                    const click = new MouseEvent('click', { bubbles: true, cancelable: true });
                    link.dispatchEvent(click);
                    return !!target && reply.contains(target) && click.defaultPrevented;
                  });
                })()
                """) as? Bool
        XCTAssertEqual(localLinks, true, "Reply sections and footnotes must resolve within that reply")
        let updated = "# 新文档内容\n\n更新后的内容。\n"
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: updated)
        await session.closeAgent()
        _ = try await bridge.call("toggleAgent")
        try await send("继续解释。", bridge: bridge)
        try await completed(bridge, count: 4)
        let requests = AgentFixtureProtocol.queue.requests()
        XCTAssertEqual(requests.count, 2)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[1]) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] ?? "" }, ["system", "user", "assistant", "user"])
        let firstContext = try ModelWireFormat.object(Data(try XCTUnwrap(messages[1]["content"]).utf8))
        let latestContext = try ModelWireFormat.object(Data(try XCTUnwrap(messages[3]["content"]).utf8))
        let background = try XCTUnwrap(latestContext["background"] as? [String: Any])
        let versions = try XCTUnwrap(background["documents"] as? [[String: String]])
        XCTAssertEqual(versions.count, 2)
        let firstID = (firstContext["reference"] as? [String: String])?["documentID"]
        let latestID = (latestContext["reference"] as? [String: String])?["documentID"]
        XCTAssertEqual(versions.first { $0["id"] == firstID }?["content"], original)
        XCTAssertEqual(versions.first { $0["id"] == latestID }?["content"], updated)
        XCTAssertNil(firstContext["background"])
        XCTAssertFalse(String(decoding: requests[1], as: UTF8.self).contains("fixture-key"))
    }

    func testInterruptedRetryReusesSnapshotAndKeepsNewDraft() async throws {
        AgentFixtureProtocol.queue.reset([
            AgentFixture(text: "已经收到的**部分回答**。", complete: false),
            AgentFixture(text: "完整的**重试回答**。", delay: 0.5),
        ])
        let (_, bridge, _, _) = try await reader("# 原文\n\n原始引用。\n")
        _ = try await bridge.call("toggleAgent")
        try await send("解释这段。", bridge: bridge)
        try await wait {
            (try await self.state(bridge)["turns"] as? [[String: Any]])?.last?["state"] as? String == "failed"
        }
        _ = try await bridge.webView.evaluateJavaScript(
            "document.querySelector('.mdv-composer textarea').value = '尚未发送的新草稿'; document.querySelector('.mdv-composer textarea').dispatchEvent(new Event('input',{bubbles:true}));"
        )
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: "# 后续文档\n\n不应进入重试请求。\n")
        _ = try await bridge.webView.evaluateJavaScript(
            "const retry = document.querySelector('[data-agent-action=retry]'); retry.click(); retry.click();")
        var result = try await state(bridge)
        XCTAssertTrue(((result["turns"] as? [[String: Any]])?.last?["text"] as? String)?.contains("部分回答") == true)
        try await completed(bridge)
        result = try await state(bridge)
        XCTAssertEqual(result["draft"] as? String, "尚未发送的新草稿")
        XCTAssertEqual((result["turns"] as? [[String: Any]])?.count, 2)
        XCTAssertFalse(((result["turns"] as? [[String: Any]])?.last?["text"] as? String)?.contains("部分回答") == true)
        let requests = AgentFixtureProtocol.queue.requests()
        XCTAssertEqual(requests.count, 2)
        let firstBody = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(requests.first)) as? NSDictionary)
        let lastBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests.last)) as? NSDictionary)
        XCTAssertEqual(firstBody, lastBody)
    }

    func testResponsesGlobalContextRefreshesAtSendAndSelectionCancelDoesNotLeak() async throws {
        AgentFixtureProtocol.queue.reset([AgentFixture(text: "**真实桥接的回答**。")])
        let (session, bridge, _, _) = try await reader("# 原始文档\n\nSELECTED_ONLY\n\nUNSELECTED\n", api: .responses)
        try await sourceMode(bridge)
        try selectSource("SELECTED_ONLY", bridge: bridge)
        _ = try await bridge.call("askSelection", arguments: ["payload": "SELECTED_ONLY"])
        try await wait { session.agentOpen }
        await session.closeAgent()
        _ = try await bridge.call("toggleAgent")
        let current = "# 当前文档\n\n完整的新内容。\n"
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: current)
        try await send("总结现在的全文。", bridge: bridge)
        try await completed(bridge)
        let bodies = AgentFixtureProtocol.queue.requests()
        XCTAssertEqual(bodies.count, 1)
        let body = try ModelWireFormat.object(XCTUnwrap(bodies.first))
        let messages = try XCTUnwrap(body["input"] as? [[String: String]])
        let context = try ModelWireFormat.object(Data(try XCTUnwrap(messages.last?["content"]).utf8))
        XCTAssertEqual((context["reference"] as? [String: String])?["scope"], "document")
        let background = try XCTUnwrap(context["background"] as? [String: Any])
        let versions = try XCTUnwrap(background["documents"] as? [[String: String]])
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?["content"], current)
        XCTAssertEqual(background["currentDocumentID"] as? String, versions.first?["id"])
        XCTAssertFalse(String(decoding: bodies[0], as: UTF8.self).contains("SELECTED_ONLY"))
    }

    func testUnconfiguredSelectionWaitsAndResumesWithOnlyItsQuote() async throws {
        AgentFixtureProtocol.queue.reset([AgentFixture(text: "所选内容的解释。")])
        final class Credential { var value = "" }
        let key = Credential()
        let (session, bridge, _, _) = try await reader("# 标题\n\nSELECTED_ONLY\n\nUNSELECTED\n", modelKey: { key.value })
        try await sourceMode(bridge)
        try selectSource("SELECTED_ONLY", bridge: bridge)
        _ = try await bridge.call("askSelection")
        try await wait { session.needsModelConfiguration }
        XCTAssertFalse(session.agentOpen)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
        session.needsModelConfiguration = false
        session.finishAgentConfiguration(saved: false)
        try selectSource("SELECTED_ONLY", bridge: bridge)
        _ = try await bridge.call("askSelection")
        try await wait { session.needsModelConfiguration }
        key.value = "fixture-key"
        session.needsModelConfiguration = false
        session.finishAgentConfiguration(saved: true)
        try await wait { session.agentOpen }
        let result = try await state(bridge)
        XCTAssertTrue((result["reference"] as? String)?.contains("SELECTED_ONLY") == true)
        XCTAssertFalse((result["reference"] as? String)?.contains("UNSELECTED") == true)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0, "Configuration must not submit a question")
        try await send("解释", bridge: bridge)
        try await completed(bridge)
        let body = try ModelWireFormat.object(XCTUnwrap(AgentFixtureProtocol.queue.requests().first))
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let context = try ModelWireFormat.object(Data(try XCTUnwrap(messages.last?["content"]).utf8))
        XCTAssertEqual((context["reference"] as? [String: String])?["content"], "SELECTED_ONLY")
        let background = try XCTUnwrap(context["background"] as? [String: Any])
        let versions = try XCTUnwrap(background["documents"] as? [[String: String]])
        XCTAssertEqual(versions.first?["content"], "# 标题\n\nSELECTED_ONLY\n\nUNSELECTED\n")
    }

    func testCollapseKeepsRequestAndExplicitStopCancelsIt() async throws {
        AgentFixtureProtocol.queue.reset([AgentFixture(waitsForCancellation: true)])
        let (session, bridge, _, _) = try await reader("# 需要总结的文档\n\n正文。\n")
        _ = try await bridge.call("toggleAgent")
        try await send("总结全文。", bridge: bridge)
        try await wait {
            session.agentTransport.activeID != nil && AgentFixtureProtocol.queue.requests().count == 1
        }
        await session.closeAgent()
        XCTAssertNotNil(session.agentTransport.activeID)
        _ = try await bridge.call("toggleAgent")
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click();")
        try await wait { session.agentTransport.activeID == nil }
        let result = try await state(bridge)
        XCTAssertEqual((result["turns"] as? [[String: Any]])?.last?["state"] as? String, "stopped")
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 1)
    }

    func testWaitingFeedbackHandsOffToTextAndClearsOnStopFailureAndCompletion() async throws {
        AgentFixtureProtocol.queue.reset([
            AgentFixture(waitsForCancellation: true),
            AgentFixture(text: "A **partial answer**.", waitsAfterText: true, complete: false),
            AgentFixture(status: 503),
            AgentFixture(text: "A complete answer."),
        ])
        let (_, bridge, _, _) = try await reader("# Document\n\nContent.\n")
        _ = try await bridge.call("toggleAgent")
        try await send("First question", bridge: bridge)
        try await wait { AgentFixtureProtocol.queue.requests().count == 1 }
        let dots = try await bridge.webView.evaluateJavaScript("document.querySelectorAll('.mdv-agent-dot').length")
        XCTAssertEqual(dots as? Int, 3)
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
        try await wait { bridge.session.agentTransport.activeID == nil }
        var remainingDots = try await bridge.webView.evaluateJavaScript(
            "document.querySelectorAll('.mdv-agent-dot').length")
        XCTAssertEqual(remainingDots as? Int, 0)

        try await send("Second question", bridge: bridge)
        try await wait {
            try await bridge.webView.evaluateJavaScript(
                "document.querySelector('.mdv-assistant-turn[data-state=streaming] strong')?.textContent === 'partial answer' && !document.querySelector('.mdv-agent-dot')"
            ) as? Bool == true
        }
        let marker = try await bridge.webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('.mdv-assistant-turn[data-state=streaming] .mdv-response-block > p'), '::after').content"
        )
        XCTAssertEqual(marker as? String, "\"\"")
        _ = try await bridge.webView.evaluateJavaScript(
            "const input = document.querySelector('.mdv-agent-input'); input.value = 'Next draft'; input.dispatchEvent(new Event('input', {bubbles:true})); document.querySelector('.mdv-agent-send').click()"
        )
        try await wait { bridge.session.agentTransport.activeID == nil }
        var result = try await state(bridge)
        XCTAssertEqual(result["draft"] as? String, "Next draft")
        XCTAssertTrue(
            ((result["turns"] as? [[String: Any]])?.last?["text"] as? String)?.contains("partial answer") == true)
        let stoppedMarker = try await bridge.webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('.mdv-assistant-turn:last-child .mdv-response-block > p'), '::after').content"
        )
        XCTAssertEqual(stoppedMarker as? String, "none")

        try await send("Third question", bridge: bridge)
        try await wait {
            (try await self.state(bridge)["turns"] as? [[String: Any]])?.last?["state"] as? String == "failed"
        }
        remainingDots = try await bridge.webView.evaluateJavaScript(
            "document.querySelectorAll('.mdv-agent-dot').length")
        XCTAssertEqual(remainingDots as? Int, 0)
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('[data-agent-action=retry]').click()")
        try await completed(bridge, count: 6)
        result = try await state(bridge)
        XCTAssertEqual((result["turns"] as? [[String: Any]])?.last?["text"] as? String, "A complete answer.")
        remainingDots = try await bridge.webView.evaluateJavaScript(
            "document.querySelectorAll('.mdv-agent-dot').length")
        XCTAssertEqual(remainingDots as? Int, 0)
    }

    func testCapsuleKeepsNativeInputAndWebSendHitRegionsSeparate() async throws {
        AgentFixtureProtocol.queue.reset([])
        let (_, bridge, _, _) = try await reader("# Document\n")
        _ = try await bridge.call("toggleAgent")
        let input = try XCTUnwrap(
            bridge.webView.superview?.subviews.compactMap { $0 as? ConversationTextView }.first)
        XCTAssertFalse(input.isDescendant(of: bridge.webView))
        try await wait { !input.isHidden && input.frame.width > 0 }
        let pixel = 1 / bridge.webView.traitCollection.displayScale
        for text in ["A short question", String(repeating: "A longer question on several lines. ", count: 20)] {
            _ = try await bridge.webView.callAsyncJavaScript(
                "const input = document.querySelector('.mdv-agent-input'); input.value = text; input.dispatchEvent(new Event('input', {bubbles:true}));",
                arguments: ["text": text], in: nil, contentWorld: .page)
            try await wait { input.text == text }
            var field = CGRect.zero
            var button = CGRect.zero
            // Web layout and its native projection cross an asynchronous bridge.
            // Compare one settled layout, allowing only physical pixel precision.
            try await wait {
                let values = try await bridge.webView.evaluateJavaScript(
                    "(() => { const panel = document.querySelector('.mdv-agent'); if (panel.getAnimations().length) return null; return ['.mdv-agent-input','.mdv-agent-send'].flatMap(selector => { const r = panel.querySelector(selector).getBoundingClientRect(); return [r.x,r.y,r.width,r.height]; }); })()"
                )
                guard let rect = values as? [Double] else { return false }
                field = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
                button = CGRect(x: rect[4], y: rect[5], width: rect[6], height: rect[7])
                let nativeFrame = input.convert(input.bounds, to: bridge.webView)
                return abs(nativeFrame.minX - field.minX) <= pixel
                    && abs(nativeFrame.minY - field.minY) <= pixel
                    && abs(nativeFrame.width - field.width) <= pixel
                    && abs(nativeFrame.height - field.height) <= pixel
            }
            XCTAssertFalse(field.intersects(button), "The input and send control must have separate layout regions")
            for x in [button.minX + pixel / 2, button.midX, button.maxX - pixel / 2] {
                for y in [button.minY + pixel / 2, button.midY, button.maxY - pixel / 2] {
                    let hit = bridge.webView.hitTest(CGPoint(x: x, y: y), with: nil)
                    XCTAssertFalse(hit === input || hit?.isDescendant(of: input) == true)
                }
            }
            XCTAssertGreaterThanOrEqual(button.width, 44)
            XCTAssertGreaterThanOrEqual(button.height, 44)
        }
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
    }

    func testComposerFollowsNativeBottomBoundaryWithoutMovingTheDocumentOrPanel() async throws {
        AgentFixtureProtocol.queue.reset([])
        let (_, bridge, window, _) = try await reader(
            "# Reading\n\nA selected passage to discuss.\n\n"
                + String(repeating: "More reading content.\n\n", count: 60))
        defer { window.endEditing(true) }
        for size in [CGSize(width: 390, height: 844), CGSize(width: 1024, height: 768)] {
            bridge.webView.autoresizingMask = []
            bridge.webView.frame = CGRect(origin: .zero, size: size)
            _ = try await bridge.webView.evaluateJavaScript(
                "(() => { const r = document.createRange(); r.selectNodeContents(document.querySelector('.mdv-article p')); const s = getSelection(); s.removeAllRanges(); s.addRange(r); window.MarkdownIt.askSelection(); })()"
            )
            try await wait { bridge.session.agentOpen }
            bridge.composer.blur()
            try await wait {
                window.keyboardLayoutGuide.layoutFrame.height <= window.safeAreaInsets.bottom + 1
            }
            let input = try XCTUnwrap(
                bridge.webView.superview?.subviews.compactMap { $0 as? ConversationTextView }.first)
            _ = try await bridge.webView.evaluateJavaScript(
                "(() => { const f = document.querySelector('.mdv-agent-input'); f.value = 'A question about this passage.'; f.dispatchEvent(new Event('input', {bubbles:true})); })()"
            )
            func geometry() async throws -> [String: Double] {
                let value = try await bridge.webView.evaluateJavaScript(
                    """
                    (() => {
                      const panel = document.querySelector('.mdv-agent'), composer = panel.querySelector('.mdv-composer');
                      if (panel.getAnimations({subtree:true}).length) return null;
                      const p = panel.getBoundingClientRect(), c = composer.getBoundingClientRect();
                      const f = panel.querySelector('textarea').getBoundingClientRect();
                      const r = panel.querySelector('.mdv-composer-reference').getBoundingClientRect();
                      const a = document.querySelector('.mdv-article').getBoundingClientRect();
                      return {panelTop:p.top, panelBottom:p.bottom, composerBottom:c.bottom, inputTop:f.top,
                        inputBottom:f.bottom, referenceTop:r.top, articleTop:a.top, articleWidth:a.width};
                    })()
                    """)
                return value as? [String: Double] ?? [:]
            }
            try await wait {
                try await geometry()["composerBottom"] != nil && input.text == "A question about this passage."
            }
            let baseline = try await geometry()
            let bottom = try XCTUnwrap(baseline["composerBottom"])
            for inset in [136.0, 72.0, 0.0] {
                // Supply measured native geometry at the bridge boundary, not a keyboard-height guess.
                bridge.webView.inputBottomInset = inset
                let target = min(bottom, size.height - inset - ReaderDesign.floatingGap)
                var result: [String: Double] = [:]
                try await wait {
                    result = try await geometry()
                    guard let actual = result["composerBottom"], let fieldTop = result["inputTop"],
                        let fieldBottom = result["inputBottom"]
                    else { return false }
                    let native = input.convert(input.bounds, to: bridge.webView)
                    return abs(actual - target) <= 1.1 && abs(native.minY - fieldTop) <= 0.5
                        && abs(native.maxY - fieldBottom) <= 0.5
                }
                for key in ["panelTop", "panelBottom", "articleTop", "articleWidth"] {
                    XCTAssertEqual(try XCTUnwrap(result[key]), try XCTUnwrap(baseline[key]), accuracy: 0.5)
                }
                let referenceOffset = try XCTUnwrap(result["inputTop"]) - XCTUnwrap(result["referenceTop"])
                let originalOffset = try XCTUnwrap(baseline["inputTop"]) - XCTUnwrap(baseline["referenceTop"])
                XCTAssertEqual(
                    referenceOffset, originalOffset, accuracy: 0.5, "Reference and input must move as one group")
                XCTAssertEqual(input.text, "A question about this passage.")
                if inset == 136 {
                    let image = try await bridge.webView.takeSnapshot(configuration: nil)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "composer-input-boundary-\(Int(size.width))"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            // A new target must replace an in-flight target, including immediate reversal.
            bridge.webView.inputBottomInset = 136
            try await wait {
                let value = try await bridge.webView.evaluateJavaScript(
                    "document.querySelector('.mdv-composer').getBoundingClientRect().bottom")
                return (value as? Double ?? bottom) < bottom - 2
            }
            bridge.webView.inputBottomInset = 72
            bridge.webView.inputBottomInset = 0
            try await wait { abs((try await geometry()["composerBottom"] ?? 0) - bottom) <= 0.5 }
            _ = try await bridge.call("closeAgent")
        }
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
    }

    func testConversationInputClearsDockedKeyboardWithoutDoubleCountingItsHeight() async throws {
        let (_, bridge, window, _) = try await reader("# Reading\n\nA passage to discuss.\n")
        defer { window.endEditing(true) }
        let controller = try XCTUnwrap(window.rootViewController)
        bridge.webView.removeFromSuperview()
        let container = ReaderContainer(webView: bridge.webView)
        container.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: controller.view.topAnchor),
            container.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
        ])
        let viewport = try XCTUnwrap(bridge.webView.superview as? ReaderViewport)
        XCTAssertTrue(viewport.keyboardLayoutGuide.followsUndockedKeyboard)
        XCTAssertFalse(viewport.keyboardLayoutGuide.usesBottomSafeArea)
        _ = try await bridge.call("toggleAgent")
        try await wait(timeout: 8) {
            bridge.session.agentOpen && container.keyboardLayoutGuide.layoutFrame.height > 0
        }
        let input = try XCTUnwrap(viewport.subviews.compactMap { $0 as? ConversationTextView }.first)
        try await wait {
            let boundary = container.convert(container.keyboardLayoutGuide.layoutFrame.origin, to: window).y
            let native = input.convert(input.bounds, to: window)
            return input.isFirstResponder && !input.isHidden && native.height > 0
                && native.maxY < boundary && abs(bridge.webView.inputBottomInset) <= 1
                && abs(viewport.frame.maxY - container.keyboardLayoutGuide.layoutFrame.minY) < 1
        }
        XCTAssertEqual(container.frame.maxY, controller.view.bounds.maxY, accuracy: 1)
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let keyboardImage = XCTAttachment(image: image)
        keyboardImage.name = "composer-docked-keyboard"
        keyboardImage.lifetime = .keepAlways
        add(keyboardImage)
        bridge.composer.blur()
        try await wait {
            abs(viewport.frame.maxY - container.bounds.maxY) < 1 && bridge.webView.inputBottomInset <= 1
        }
        _ = try await bridge.call("closeAgent")
    }

    func testAdaptivePanelsShareWidthPolicyAndPreserveConversationAndNavigation() async throws {
        AgentFixtureProtocol.queue.reset([
            AgentFixture(text: String(repeating: "An answer paragraph to retain while changing panels.\n\n", count: 40))
        ])
        let markdown =
            "# Reading\n\n"
            + (1...35).map {
                "## Chapter \($0)\n\n" + String(repeating: "Document paragraph for reading.\n\n", count: 8)
                    + "### Detail \($0)\n\nMore content.\n\n"
            }.joined()
        let (session, bridge, _, _) = try await reader(markdown)
        func settled() async throws {
            try await wait {
                try await bridge.webView.evaluateJavaScript(
                    "document.querySelector('.mdv-app').getAnimations({subtree:true}).every(a=>a.playState==='finished')"
                ) as? Bool == true
            }
        }
        func resize(_ width: Double, _ height: Double = 1000) async throws {
            bridge.webView.frame = CGRect(x: 0, y: 0, width: width, height: height)
            try await wait {
                try await bridge.webView.callAsyncJavaScript(
                    """
                    const app = document.querySelector('.mdv-app');
                    const style = getComputedStyle(app);
                    const value = name => parseFloat(style.getPropertyValue(name));
                    const outlineSide = width >= value('--mdv-document-minimum-width') + value('--mdv-outline-width');
                    const agentSide = width >= value('--mdv-document-minimum-width') + value('--mdv-agent-minimum-width') + 2 * value('--mdv-agent-edge-inset');
                    return innerWidth === width && innerHeight === height && app.clientWidth === width
                      && app.dataset.outlineLayout === (outlineSide ? 'side' : 'overlay')
                      && app.dataset.agentLayout === (agentSide ? 'side' : 'sheet');
                    """, arguments: ["width": width, "height": height], in: nil, contentWorld: .page) as? Bool == true
            }
            // ResizeObserver reconciles the panel policy after viewport geometry changes.
            // Its resulting transition must finish before comparing native and Web geometry.
            try await settled()
        }
        func panels(outline: Bool, agent: Bool, sheet: Bool) async throws {
            try await wait {
                session.outlineExpanded == outline && session.agentOpen == agent && session.agentVisible == agent
                    && session.agentModalActive == sheet
            }
            var documentLeading: Double?
            try await wait {
                let geometry =
                    try await bridge.webView.callAsyncJavaScript(
                        """
                        const layout = document.querySelector('.mdv-reading-layout');
                        const leading = document.querySelector('.mdv-reader').getBoundingClientRect().left;
                        const animations = document.querySelector('.mdv-app').getAnimations({subtree:true});
                        return layout.classList.contains('mdv-with-outline') === outline
                          && animations.every(a => a.playState === 'finished') ? leading : null;
                        """, arguments: ["outline": outline], in: nil, contentWorld: .page) as? Double
                documentLeading = geometry
                return geometry.map { abs(session.documentLeading - $0) <= 1 } ?? false
            }
            XCTAssertEqual(session.documentLeading, try XCTUnwrap(documentLeading), accuracy: 1)
            let status = try await self.state(bridge)
            XCTAssertEqual(status["draft"] as? String, "Draft kept across layouts")
            XCTAssertEqual((status["turns"] as? [[String: Any]])?.count, 2)
        }
        func openAI() async throws {
            _ = try await bridge.call("toggleAgent")
            try await wait { session.agentOpen }
        }
        try await resize(1376)
        if !session.outlineExpanded { _ = try await bridge.call("toggleOutline") }
        try await openAI()
        try await send("Keep this conversation", bridge: bridge)
        try await completed(bridge)
        _ = try await bridge.webView.evaluateJavaScript(
            "const input=document.querySelector('.mdv-agent-input'); input.value='Draft kept across layouts'; input.dispatchEvent(new Event('input',{bubbles:true}));"
        )
        try await panels(outline: true, agent: true, sheet: false)
        _ = try await bridge.webView.evaluateJavaScript(
            "const conversation=document.querySelector('.mdv-agent-scroll'); conversation.dispatchEvent(new WheelEvent('wheel',{deltaY:-100})); conversation.scrollTop=80;"
        )
        _ = try await bridge.call("scrollToSourceLine", arguments: ["payload": 120])
        try await wait { try await bridge.webView.evaluateJavaScript("window.scrollY > 0") as? Bool == true }
        _ = try await bridge.webView.evaluateJavaScript(
            "const body=document.querySelector('.mdv-outline-body'); body.dispatchEvent(new WheelEvent('wheel',{deltaY:100,bubbles:true})); body.scrollTop=120; const chapter=document.querySelector('.mdv-article h2'); const chapterToggle=document.querySelector('[data-toc-target=\"'+chapter.id+'\"]').parentElement.querySelector('[data-collapse-heading]'); chapterToggle.click();"
        )
        try await resize(834)
        try await panels(outline: true, agent: false, sheet: false)
        let anchor = try await bridge.call("diagnostics") as? [String: Any]
        let position = try XCTUnwrap(anchor?["anchor"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(position["line"] as? Double), 120, accuracy: 1)
        try await openAI()
        try await panels(outline: false, agent: true, sheet: false)
        let conversationPosition =
            try await bridge.webView.evaluateJavaScript(
                "document.querySelector('.mdv-agent-scroll').scrollTop") as? Double
        XCTAssertEqual(
            try XCTUnwrap(conversationPosition), 80, accuracy: 1,
            "Switching auxiliary panels must preserve manual conversation browsing")
        let geometry =
            try await bridge.webView.evaluateJavaScript(
                "(() => { const r=document.querySelector('.mdv-reader').getBoundingClientRect(), a=document.querySelector('.mdv-agent').getBoundingClientRect(); return [r.width,r.right,a.left,a.width]; })()"
            ) as? [Double]
        let widths = try XCTUnwrap(geometry)
        XCTAssertGreaterThanOrEqual(widths[0], 420)
        XCTAssertGreaterThanOrEqual(widths[2] - widths[1], 15)
        XCTAssertEqual(widths[3], 320, accuracy: 1)
        let reservedWidth = try await bridge.webView.evaluateJavaScript(
            "parseFloat(getComputedStyle(document.querySelector('.mdv-app')).getPropertyValue('--mdv-agent-reserved-width'))"
        )
        XCTAssertEqual(reservedWidth as? Double, 352)
        _ = try await bridge.call("toggleOutline")
        try await panels(outline: true, agent: false, sheet: false)
        let navigationKept =
            try await bridge.webView.evaluateJavaScript(
                "chapterToggle.getAttribute('aria-expanded')==='false' && document.querySelector('.mdv-outline-body').scrollTop > 0"
            ) as? Bool
        XCTAssertEqual(navigationKept, true)
        try await openAI()
        try await resize(834, 430)
        try await panels(outline: false, agent: true, sheet: false)
        try await resize(1376)
        try await panels(outline: false, agent: true, sheet: false)
        _ = try await bridge.call("toggleOutline")
        try await panels(outline: true, agent: true, sheet: false)
        _ = try await bridge.call("agentInteraction")
        try await resize(834)
        try await panels(outline: false, agent: true, sheet: false)
        try await resize(500)
        try await panels(outline: false, agent: true, sheet: true)
        _ = try await bridge.call("toggleOutline")
        try await panels(outline: true, agent: false, sheet: false)
        let closedWidth = try await bridge.webView.evaluateJavaScript(
            "parseFloat(getComputedStyle(document.querySelector('.mdv-app')).getPropertyValue('--mdv-agent-reserved-width'))"
        )
        XCTAssertEqual(closedWidth as? Double, 0)
        _ = try await bridge.call("toggleOutline")
        try await panels(outline: false, agent: false, sheet: false)
        for _ in 0..<3 {
            try await openAI()
            _ = try await bridge.call("toggleOutline")
        }
        try await panels(outline: true, agent: false, sheet: false)
        try await resize(1376)
        try await panels(outline: true, agent: false, sheet: false)
        try await sourceMode(bridge)
        _ = try await bridge.call("scrollToSourceLine", arguments: ["payload": 120])
        let sourcePosition = bridge.sourceEditor.capturePosition().line
        try await openAI()
        try await settled()
        XCTAssertEqual(bridge.sourceEditor.capturePosition().line, sourcePosition, accuracy: 1)
        try await resize(834)
        XCTAssertEqual(bridge.sourceEditor.capturePosition().line, sourcePosition, accuracy: 1)
    }

    private func scrollingConversation() async throws -> ReaderBridge {
        AgentFixtureProtocol.queue.reset([
            AgentFixture(
                text: String(repeating: "A paragraph in the answer.\n\n", count: 20), waitsAfterText: true,
                complete: false)
        ])
        let (_, bridge, _, _) = try await reader("# Document\n\nContent.\n")
        _ = try await bridge.call("toggleAgent")
        // Programmatic scroll offsets are meaningful after the panel's
        // presentation has settled, rather than during its moving transform.
        try await wait {
            try await bridge.webView.evaluateJavaScript(
                "(() => { const panel = document.querySelector('.mdv-agent'); return !panel.hidden && !panel.inert && panel.getAnimations().length === 0; })()"
            ) as? Bool == true
        }
        try await send("Explain the document", bridge: bridge)
        try await wait {
            (try await self.state(bridge)["turns"] as? [[String: Any]])?.last?["state"] as? String == "streaming"
        }
        // Streaming starts while individual answer blocks are still entering.
        // This geometry test needs the complete rendered surface, including
        // those child animations, before assigning programmatic scroll offsets.
        try await wait {
            try await bridge.webView.evaluateJavaScript(
                "document.querySelector('.mdv-app').getAnimations({subtree:true}).every(animation => animation.playState === 'finished')"
            ) as? Bool == true
        }
        return bridge
    }

    func testReplyFollowsViewportChangesAndYieldsToManualBrowsing() async throws {
        let bridge = try await scrollingConversation()
        let atBottom =
            "(() => { const s = document.querySelector('.mdv-agent-scroll'); return Math.abs(s.scrollHeight - s.clientHeight - s.scrollTop) < 1; })()"
        _ = try await bridge.webView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').style.maxHeight = '96px'")
        try await wait(timeout: 3) { try await bridge.webView.evaluateJavaScript(atBottom) as? Bool == true }

        _ = try await bridge.webView.evaluateJavaScript(
            "(() => { const s = document.querySelector('.mdv-agent-scroll'); s.dispatchEvent(new WheelEvent('wheel', {deltaY:-100})); s.scrollTop = 0; s.style.maxHeight = '140px'; })()"
        )
        try await wait {
            try await bridge.webView.evaluateJavaScript(
                "document.querySelector('.mdv-agent-scroll').clientHeight === 140") as? Bool == true
        }
        let manualPosition = try await bridge.webView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').scrollTop")
        XCTAssertEqual(manualPosition as? Double, 0)
        _ = try await bridge.webView.evaluateJavaScript(
            "(() => { const s = document.querySelector('.mdv-agent-scroll'); s.scrollTop = s.scrollHeight; s.dispatchEvent(new WheelEvent('wheel', {deltaY:100})); })()"
        )
        _ = try await bridge.webView.callAsyncJavaScript(
            "await new Promise(requestAnimationFrame); document.querySelector('.mdv-agent-scroll').style.maxHeight = '80px';",
            arguments: [:], in: nil, contentWorld: .page)
        try await wait(timeout: 3) { try await bridge.webView.evaluateJavaScript(atBottom) as? Bool == true }
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
    }

    func testConversationFollowingCorrectsALateScrollAfterViewportResize() async throws {
        let bridge = try await scrollingConversation()
        _ = try await bridge.webView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').style.maxHeight = '140px'")
        try await wait {
            try await bridge.webView.evaluateJavaScript(
                "(() => { const s = document.querySelector('.mdv-agent-scroll'); return s.clientHeight === 140 && Math.abs(s.scrollHeight - s.clientHeight - s.scrollTop) < 1; })()"
            ) as? Bool == true
        }
        let result =
            try await bridge.webView.callAsyncJavaScript(
                """
                const s = document.querySelector('.mdv-agent-scroll');
                const frame = () => new Promise(requestAnimationFrame);
                const gap = () => s.scrollHeight - s.clientHeight - s.scrollTop;
                const previousTop = s.scrollTop;
                s.style.maxHeight = '80px';
                await frame();
                await frame();
                const resizedGap = gap();
                // A delayed scrolling update can arrive after the resize observer
                // has already placed the conversation at its new bottom.
                s.scrollTop = previousTop;
                const delayedGap = gap();
                await frame();
                await frame();
                return { resizedGap, delayedGap, settledGap: gap() };
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Double]
        let positions = try XCTUnwrap(result)
        XCTAssertEqual(try XCTUnwrap(positions["resizedGap"]), 0, accuracy: 1)
        XCTAssertGreaterThan(try XCTUnwrap(positions["delayedGap"]), 56)
        XCTAssertEqual(
            try XCTUnwrap(positions["settledGap"]), 0, accuracy: 1,
            "Following remains active after a late scrolling update: \(positions)")
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
    }

    func testConversationFollowingSurvivesReturningToBottomAndResizingInTheSameFrame() async throws {
        let bridge = try await scrollingConversation()
        _ = try await bridge.webView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').style.maxHeight = '140px'")
        try await wait {
            try await bridge.webView.evaluateJavaScript(
                "(() => { const s = document.querySelector('.mdv-agent-scroll'); return s.clientHeight === 140 && Math.abs(s.scrollHeight - s.clientHeight - s.scrollTop) < 1; })()"
            ) as? Bool == true
        }
        let result =
            try await bridge.webView.callAsyncJavaScript(
                """
                const s = document.querySelector('.mdv-agent-scroll');
                const measure = () => ({ top: s.scrollTop, height: s.clientHeight, total: s.scrollHeight,
                  gap: s.scrollHeight - s.clientHeight - s.scrollTop });
                const frame = () => new Promise(requestAnimationFrame);
                s.dispatchEvent(new WheelEvent('wheel', { deltaY: -100 }));
                s.scrollTop = 0;
                await frame();
                await frame();
                const browsing = measure();
                s.scrollTop = s.scrollHeight;
                const returned = measure();
                s.dispatchEvent(new WheelEvent('wheel', { deltaY: 100 }));
                s.style.maxHeight = '80px';
                const resized = measure();
                await frame();
                await frame();
                return { browsing, returned, resized, settled: measure() };
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: [String: Double]]
        let positions = try XCTUnwrap(result)
        XCTAssertEqual(positions["browsing"]?["top"], 0, "Manual browsing: \(positions)")
        XCTAssertEqual(try XCTUnwrap(positions["returned"]?["gap"]), 0, accuracy: 1, "Return: \(positions)")
        XCTAssertEqual(positions["settled"]?["height"], 80)
        XCTAssertEqual(try XCTUnwrap(positions["settled"]?["gap"]), 0, accuracy: 1, "Resize: \(positions)")
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
    }

    func testPendingConversationFollowYieldsToNewerUpwardNavigation() async throws {
        let bridge = try await scrollingConversation()
        _ = try await bridge.webView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').style.maxHeight = '140px'")
        try await wait {
            try await bridge.webView.evaluateJavaScript(
                "(() => { const s = document.querySelector('.mdv-agent-scroll'); return s.clientHeight === 140 && Math.abs(s.scrollHeight - s.clientHeight - s.scrollTop) < 1; })()"
            ) as? Bool == true
        }
        let result =
            try await bridge.webView.callAsyncJavaScript(
                """
                const s = document.querySelector('.mdv-agent-scroll');
                const frame = () => new Promise(requestAnimationFrame);
                s.dispatchEvent(new WheelEvent('wheel', { deltaY: -100 }));
                s.scrollTop = 0;
                await frame();
                await frame();
                s.dispatchEvent(new WheelEvent('wheel', { deltaY: 100 }));
                s.dispatchEvent(new WheelEvent('wheel', { deltaY: -100 }));
                s.scrollTop = s.scrollHeight - s.clientHeight - 20;
                const manual = s.scrollTop;
                await frame();
                await frame();
                s.style.maxHeight = '80px';
                await frame();
                await frame();
                return { manual, actual: s.scrollTop, gap: s.scrollHeight - s.clientHeight - s.scrollTop };
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Double]
        let positions = try XCTUnwrap(result)
        XCTAssertEqual(
            try XCTUnwrap(positions["actual"]), try XCTUnwrap(positions["manual"]), accuracy: 1,
            "A queued downward action must not override newer upward navigation: \(positions)")
        XCTAssertGreaterThan(try XCTUnwrap(positions["gap"]), 56)
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
    }

    func testTouchFollowingResumesWhenMomentumReachesTheEndAfterRelease() async throws {
        let bridge = try await scrollingConversation()
        _ = try await bridge.webView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').style.maxHeight = '140px'")
        try await wait {
            try await bridge.webView.evaluateJavaScript(
                "document.querySelector('.mdv-agent-scroll').clientHeight === 140") as? Bool == true
        }
        let result =
            try await bridge.webView.callAsyncJavaScript(
                """
                const s = document.querySelector('.mdv-agent-scroll');
                const frame = () => new Promise(requestAnimationFrame);
                const touch = (type, y) => {
                  const event = new Event(type);
                  Object.defineProperty(event, 'touches', { value: y === null ? [] : [{ clientY: y }] });
                  s.dispatchEvent(event);
                };
                s.dispatchEvent(new WheelEvent('wheel', { deltaY: -100 }));
                s.scrollTop = 0;
                await frame();
                await frame();
                touch('touchstart', 200);
                touch('touchmove', 100);
                touch('touchend', null);
                await frame();
                await frame();
                // Momentum can reach the end later than the touchend callback.
                s.scrollTop = s.scrollHeight;
                await frame();
                await frame();
                const returnedGap = s.scrollHeight - s.clientHeight - s.scrollTop;
                s.style.maxHeight = '80px';
                await frame();
                await frame();
                return { returnedGap, resizedGap: s.scrollHeight - s.clientHeight - s.scrollTop };
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Double]
        let positions = try XCTUnwrap(result)
        XCTAssertEqual(try XCTUnwrap(positions["returnedGap"]), 0, accuracy: 1)
        XCTAssertEqual(
            try XCTUnwrap(positions["resizedGap"]), 0, accuracy: 1,
            "Downward touch momentum must restore following: \(positions)")
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
    }

    private func selectSource(_ text: String, bridge: ReaderBridge) throws {
        let range = (bridge.sourceEditor.history.text as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { throw CocoaError(.coderReadCorrupt) }
        bridge.sourceEditor.textView.selectedRange = range
    }

    func testSelectionQuoteKeepsEveryLineOutsideTheRemovalTargetWhileScrolling() async throws {
        let paragraph = String(repeating: "重要作品完成实质性修改。综合创作先处理整体表达，再处理视听细节。", count: 12)
        let markdown = """
            \(paragraph)

            | 项目 | 第一阶段 | 第二阶段 | 第三阶段 |
            | --- | --- | --- | --- |
            | 作品 | 调整结构 | 修改内容 | 检查表达 |

            ```swift
            let message = "Long code remains scrollable within the quote content area."
            ```

            最后一个段落。
            """
        let (_, bridge, _, _) = try await reader(markdown)
        for width in [390.0, 1024.0] {
            bridge.webView.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            try await wait {
                try await bridge.webView.evaluateJavaScript("window.innerWidth") as? Double == width
            }
            _ = try await bridge.webView.evaluateJavaScript(
                "(() => { const range=document.createRange(); range.selectNodeContents(document.querySelector('.mdv-article')); getSelection().removeAllRanges(); getSelection().addRange(range); })()"
            )
            _ = try await bridge.call("askSelection")
            try await wait {
                try await bridge.webView.evaluateJavaScript(
                    "(() => { const panel=document.querySelector('.mdv-agent'); return !panel.hidden && panel.getAnimations().every(a => a.playState === 'finished'); })()"
                ) as? Bool == true
            }
            let measured =
                try await bridge.webView.evaluateJavaScript(
                    """
                    (() => {
                      const row = document.querySelector('.mdv-reference-row');
                      const body = row.querySelector('.mdv-reference-body');
                      const remove = row.querySelector('.mdv-reference-remove');
                      const content = body.querySelector('.mdv-rich-text');
                      const paragraph = content.querySelector('p');
                      const range = document.createRange();
                      range.selectNodeContents(paragraph);
                      const lines = [...range.getClientRects()];
                      const target = remove.getBoundingClientRect();
                      const marker = row.querySelector('.mdv-reference-icon').getBoundingClientRect();
                      const start = target.top;
                      body.scrollTop = body.scrollHeight;
                      return {
                        outside: lines.every(line => line.right <= target.left),
                        lines: lines.length,
                        width: target.width, height: target.height,
                        alignment: marker.top + marker.height / 2 - (target.top + target.height / 2),
                        scrolled: body.scrollTop,
                        removalMovement: remove.getBoundingClientRect().top - start,
                        contentBoundary: content.getBoundingClientRect().right,
                        targetBoundary: target.left,
                        text: content.textContent,
                        tables: content.querySelectorAll('table').length,
                        code: content.querySelectorAll('pre code').length
                      };
                    })()
                    """
                ) as? [String: Any]
            let geometry = try XCTUnwrap(measured)
            XCTAssertEqual(geometry["outside"] as? Bool, true, "Every wrapped line must avoid the removal target")
            XCTAssertGreaterThan(try XCTUnwrap(geometry["lines"] as? Int), 3)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(geometry["width"] as? Double), 44)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(geometry["height"] as? Double), 44)
            XCTAssertEqual(try XCTUnwrap(geometry["alignment"] as? Double), 0, accuracy: 0.5)
            XCTAssertGreaterThan(try XCTUnwrap(geometry["scrolled"] as? Double), 0)
            XCTAssertEqual(try XCTUnwrap(geometry["removalMovement"] as? Double), 0, accuracy: 0.5)
            XCTAssertLessThanOrEqual(
                try XCTUnwrap(geometry["contentBoundary"] as? Double),
                try XCTUnwrap(geometry["targetBoundary"] as? Double))
            XCTAssertTrue((geometry["text"] as? String)?.contains(paragraph) == true)
            XCTAssertTrue((geometry["text"] as? String)?.contains("最后一个段落。") == true)
            XCTAssertEqual(geometry["tables"] as? Int, 1)
            XCTAssertEqual(geometry["code"] as? Int, 1)
            _ = try await bridge.webView.evaluateJavaScript(
                "document.querySelector('.mdv-reference-body').scrollTop=0;")
            let snapshot = try await bridge.webView.takeSnapshot(configuration: nil)
            let attachment = XCTAttachment(image: snapshot)
            attachment.name = "selection-quote-alignment-\(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            _ = try await bridge.webView.evaluateJavaScript(
                "document.querySelector('.mdv-reference-remove').click();")
            let state = try await state(bridge)
            XCTAssertEqual(state["referenceHTML"] as? String, "")
            _ = try await bridge.call("closeAgent")
            try await wait { !bridge.session.agentVisible }
        }
    }

    private func editCall(_ text: String, before: String, after: String, id: String = "edit-1") throws -> ModelToolCall
    {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "revision": AgentDocumentTools.revision(text), "edits": [["before": before, "after": after]],
            ], options: .sortedKeys)
        return ModelToolCall(id: id, name: "edit_document", arguments: String(decoding: data, as: UTF8.self))
    }

    func testSourceAgentEditsFileAndSharesUndoRedoWithManualEditing() async throws {
        let original = "# 文档\n\n需要修改的原文。\n\n保留这一段。\n"
        let applied = original.replacingOccurrences(of: "需要修改的原文。", with: "新的 **内容**。")
        for api in ModelAPIProtocol.allCases {
            AgentFixtureProtocol.queue.reset([
                AgentFixture(calls: [try editCall(original, before: "需要修改的原文。", after: "新的 **内容**。")]),
                AgentFixture(text: "已修改，其他段落保持原样。"), AgentFixture(text: "这是原文的解释。"),
            ])
            let (session, bridge, _, url) = try await reader(original, api: api)
            try await sourceMode(bridge)
            _ = try await bridge.call("toggleAgent")
            try await send("把第一段改为新的 **内容**。", bridge: bridge)
            try await completed(bridge)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), applied)
            let requests = AgentFixtureProtocol.queue.requests()
            XCTAssertEqual(requests.count, 2)
            let continuation = try ModelWireFormat.object(requests[1])
            let wire = String(decoding: requests[1], as: UTF8.self)
            XCTAssertTrue(wire.contains("edit-1"))
            XCTAssertTrue(wire.contains("saved"))
            XCTAssertEqual((continuation["tools"] as? [[String: Any]])?.count, 2)
            XCTAssertFalse(wire.contains("fixture-key"))
            // Deliver the native save acknowledgement only after a later history action.
            _ = try await bridge.webView.evaluateJavaScript(
                """
                (() => {
                  const deliver = window.MarkdownIt.agentUndoResult.bind(window.MarkdownIt);
                  window.MarkdownIt.agentUndoResult = payload => {
                    window.delayedUndoResult = () => {
                      window.MarkdownIt.agentUndoResult = deliver;
                      delete window.delayedUndoResult;
                      deliver(payload);
                    };
                  };
                })();
                """)
            _ = try await bridge.webView.evaluateJavaScript(
                "document.querySelector('[data-agent-action=undo]').click();")
            try await wait { session.document?.text == original }
            await session.flushChanges()
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
            try await wait {
                try await bridge.webView.evaluateJavaScript("typeof window.delayedUndoResult === 'function'")
                    as? Bool == true
            }
            let redone = bridge.moveSourceHistory(forward: true)
            XCTAssertEqual(redone, true)
            try await wait { session.document?.text == applied }
            _ = try await bridge.webView.evaluateJavaScript("window.delayedUndoResult();")
            let undoVisible =
                try await bridge.webView.evaluateJavaScript(
                    "!document.querySelector('[data-agent-action=undo]').hidden") as? Bool
            XCTAssertEqual(undoVisible, true)
            _ = bridge.moveSourceHistory(forward: false)
            _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: original + "手动追加。\n")
            let unavailable =
                bridge.moveSourceHistory(forward: true)
            XCTAssertEqual(unavailable, false)
            try await send("只解释原文，不要修改。", bridge: bridge)
            try await completed(bridge, count: 4)
            XCTAssertEqual(session.document?.text, original + "手动追加。\n")
            let body = try ModelWireFormat.object(XCTUnwrap(AgentFixtureProtocol.queue.requests().last))
            let history = try XCTUnwrap(body[api == .responses ? "input" : "messages"] as? [[String: Any]])
            let previousReply = try ModelWireFormat.object(
                Data(try XCTUnwrap(history.first { $0["role"] as? String == "assistant" }?["content"] as? String).utf8))
            XCTAssertEqual((previousReply["sourceChanges"] as? [[String: String]])?.first?["status"], "undone")
        }
    }

    func testDelayedUndoProjectionCannotOverwriteANewerNativeRedo() async throws {
        let original = "# Document\n\nOriginal paragraph.\n"
        let applied = original.replacingOccurrences(of: "Original", with: "Revised")
        let (session, bridge, _, url) = try await reader(original)
        try await sourceMode(bridge)
        let execution = await session.agentDocuments.execute(
            try editCall(original, before: "Original", after: "Revised"), token: session.documentToken)
        let change = try XCTUnwrap(execution.change)
        XCTAssertEqual(change.saved, true)
        _ = try await bridge.webView.evaluateJavaScript(
            """
            (() => {
              const deliver = window.MarkdownIt.sourceState.bind(window.MarkdownIt);
              window.MarkdownIt.sourceState = payload => {
                if (!payload.events.some(event => event.status === 'undone')) return deliver(payload);
                return new Promise(resolve => {
                  window.releaseUndoProjection = () => {
                    delete window.releaseUndoProjection;
                    window.MarkdownIt.sourceState = deliver;
                    resolve(deliver(payload));
                  };
                });
              };
            })();
            """)
        let token = session.documentToken
        var undoFinished = false
        let undo = Task {
            let result = await session.agentDocuments.undo(change.id, token: token)
            undoFinished = true
            return result
        }
        try await wait {
            let held =
                try await bridge.webView.evaluateJavaScript("typeof window.releaseUndoProjection === 'function'")
                as? Bool == true
            return session.document?.text == original && held
        }
        bridge.sourceEditor.history.undoManager.redo()
        XCTAssertEqual(session.document?.text, applied)
        try await wait { undoFinished }
        XCTAssertEqual(session.document?.text, applied)
        _ = try await bridge.webView.evaluateJavaScript("window.releaseUndoProjection();")
        let result = await undo.value
        XCTAssertEqual(result["status"], "undone")
        XCTAssertEqual(session.document?.text, applied, "A delayed renderer response cannot write an old snapshot")
        await session.flushChanges()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), applied)
        _ = try await bridge.call("toggleAgent")
        let source = try await bridge.webView.evaluateJavaScript("window.MarkdownIt.diagnostics().source") as? String
        XCTAssertEqual(source, applied, "The renderer eventually receives the latest native revision")
    }

    func testSourceToolRejectsStaleAmbiguousAndOverlappingChangesAtomically() async throws {
        let original = "# 文档\n\n重复。重复。\n\n唯一原文。\n"
        let (session, bridge, _, url) = try await reader(original)
        try await sourceMode(bridge)
        let token = session.documentToken
        let ambiguous = try editCall(original, before: "重复。", after: "错误")
        let rejected = await session.agentDocuments.execute(ambiguous, token: token)
        XCTAssertTrue(rejected.output.contains("invalid_edit"))
        let data = try JSONSerialization.data(withJSONObject: [
            "revision": AgentDocumentTools.revision(original),
            "edits": [["before": "唯一原文。", "after": "x"], ["before": "原文。", "after": "y"]],
        ])
        let overlap = await session.agentDocuments.execute(
            .init(id: "overlap", name: "edit_document", arguments: String(decoding: data, as: UTF8.self)), token: token)
        XCTAssertTrue(overlap.output.contains("invalid_edit"))
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: original + "手动编辑。")
        let stale = await session.agentDocuments.execute(
            try editCall(original, before: "唯一原文。", after: "新内容。"), token: token)
        XCTAssertTrue(stale.output.contains("stale_document"))
        await session.flushChanges()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original + "手动编辑。")
        _ = try await bridge.call("toggleMode")
        try await wait { (try await bridge.call("diagnostics") as? [String: Any])?["mode"] as? String == "preview" }
        let readOnly = await session.agentDocuments.execute(ambiguous, token: token)
        XCTAssertTrue(readOnly.output.contains("read_only"))
        XCTAssertEqual(session.document?.text, original + "手动编辑。")
    }

    func testRetryAfterAppliedToolDoesNotExecuteTheEditTwice() async throws {
        let original = "# 文档\n\n原文。\n"
        let call = try editCall(original, before: "原文。", after: "新文。")
        AgentFixtureProtocol.queue.reset([
            AgentFixture(calls: [call]), AgentFixture(status: 503), AgentFixture(text: "修改已保存。"),
        ])
        let (session, bridge, _, _) = try await reader(original, api: .responses)
        try await sourceMode(bridge)
        _ = try await bridge.call("toggleAgent")
        try await send("把原文改为新文。", bridge: bridge)
        try await wait {
            (try await self.state(bridge)["turns"] as? [[String: Any]])?.last?["state"] as? String == "failed"
        }
        XCTAssertEqual(session.document?.text, "# 文档\n\n新文。\n")
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('[data-agent-action=retry]').click();")
        try await completed(bridge)
        let requests = AgentFixtureProtocol.queue.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1], requests[2])
        let cards =
            try await bridge.webView.evaluateJavaScript(
                "document.querySelectorAll('[data-component=DocumentChange]').length") as? Int
        XCTAssertEqual(cards, 1)
        _ = bridge.moveSourceHistory(forward: false)
        try await wait { session.document?.text == original }
        XCTAssertFalse(session.canUndoSource)
    }

    func testStoppingAfterAToolEditKeepsTheChangeVisibleAndUndoable() async throws {
        let original = "# 文档\n\n原文。\n"
        AgentFixtureProtocol.queue.reset([
            AgentFixture(calls: [try editCall(original, before: "原文。", after: "新文。")]),
            AgentFixture(text: "这条延迟的说明不应出现在停止后的回答中。", delay: 3),
        ])
        let (session, bridge, _, url) = try await reader(original, api: .responses)
        try await sourceMode(bridge)
        _ = try await bridge.call("toggleAgent")
        try await send("把原文改为新文。", bridge: bridge)
        try await wait { session.document?.text == "# 文档\n\n新文。\n" }
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click();")
        try await wait { session.agentTransport.activeID == nil }
        try await wait {
            try await bridge.webView.evaluateJavaScript(
                "document.querySelectorAll('[data-component=DocumentChange]').length") as? Int == 1
        }
        await session.flushChanges()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# 文档\n\n新文。\n")
        let turns = try await state(bridge)["turns"] as? [[String: Any]]
        XCTAssertEqual(turns?.last?["state"] as? String, "stopped")
        _ = bridge.moveSourceHistory(forward: false)
        try await wait { session.document?.text == original }
        _ = bridge.moveSourceHistory(forward: true)
        try await wait { session.document?.text == "# 文档\n\n新文。\n" }
    }

    func testRepeatedToolsPauseRemainingCallsInTheSameModelTurn() async throws {
        let doc = AgentAttachment(
            text: "Document", markdown: "Document", mode: "source", scope: "document", location: nil, start: nil,
            end: nil)
        let snapshot = AgentSnapshot(
            question: "Read and edit the document", attachment: doc,
            history: [.init(role: "user", markdown: "Read and edit the document", attachment: doc, document: doc)],
            document: doc)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentFixtureProtocol.self]
        let transport = AgentModelTransport(client: ModelClient(session: URLSession(configuration: configuration)))
        AgentFixtureProtocol.queue.reset([
            AgentFixture(calls: [
                ModelToolCall(id: "first", name: "read_document", arguments: "{}"),
                ModelToolCall(id: "repeated", name: "read_document", arguments: "{}"),
                ModelToolCall(id: "remaining", name: "edit_document", arguments: "{}"),
            ]), AgentFixture(text: "Stopped tools"),
        ])
        var executed: [String] = []
        var finished = false
        transport.start(
            id: UUID().uuidString, token: "document", snapshot: snapshot, intent: "question",
            configuration: .init(
                baseURL: "https://agent.example.test/v1", model: "fixture", apiProtocol: .chatCompletions),
            key: "fixture-key",
            toolsAvailable: { true },
            executeTool: { call, _ in
                executed.append(call.name)
                return AgentToolExecution(output: "unchanged", revision: "same")
            },
            emit: { event in
                if event.type == "failure" { XCTFail("Unexpected transport failure") }
                if event.type == "complete" { finished = true }
            })
        try await wait { finished }
        XCTAssertEqual(executed, ["read_document", "read_document"])
        let last = try ModelWireFormat.object(XCTUnwrap(AgentFixtureProtocol.queue.requests().last))
        XCTAssertEqual((last["tools"] as? [[String: Any]])?.count, 0)
        let messages = try XCTUnwrap(last["messages"] as? [[String: Any]])
        let outputs = messages.filter { $0["role"] as? String == "tool" }
        XCTAssertEqual(outputs.count, 3, "Every declared call still needs a result in the following model request")
        XCTAssertTrue((outputs.last?["content"] as? String)?.contains("repeated_without_progress") == true)
    }

    func testToolLoopGuardUsesRepeatedResultsRatherThanFixedRoundCount() async throws {
        let doc = AgentAttachment(
            text: "正文", markdown: "正文", mode: "source", scope: "document", location: nil, start: nil, end: nil)
        let snapshot = AgentSnapshot(
            question: "读取文档", attachment: doc,
            history: [.init(role: "user", markdown: "读取文档", attachment: doc, document: doc)], document: doc)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentFixtureProtocol.self]
        let transport = AgentModelTransport(client: ModelClient(session: URLSession(configuration: configuration)))
        let call = ModelToolCall(id: "read", name: "read_document", arguments: "{}")
        for progress in [true, false] {
            let rounds = progress ? 11 : 2
            AgentFixtureProtocol.queue.reset(
                Array(repeating: AgentFixture(calls: [call]), count: rounds) + [AgentFixture(text: "完成")])
            var count = 0
            var finished = false
            transport.reset()
            transport.start(
                id: UUID().uuidString, token: "document", snapshot: snapshot, intent: "question",
                configuration: .init(baseURL: "https://agent.example.test/v1", model: "fixture"), key: "fixture-key",
                toolsAvailable: { true },
                executeTool: { _, _ in
                    count += 1
                    let revision = progress ? String(count) : "unchanged"
                    return AgentToolExecution(output: "{\"revision\":\"" + revision + "\"}", revision: revision)
                },
                emit: { event in
                    if event.type == "failure" { XCTFail("Unexpected transport failure") }
                    if event.type == "complete" { finished = true }
                })
            try await wait { finished }
            XCTAssertEqual(count, rounds)
            let last = try ModelWireFormat.object(XCTUnwrap(AgentFixtureProtocol.queue.requests().last))
            XCTAssertEqual((last["tools"] as? [[String: Any]])?.count, progress ? 2 : 0)
        }
    }
    func testStandaloneAndMixedImageReferencesSendPixelsAndKeepSnapshots() async throws {
        for api in ModelAPIProtocol.allCases {
            AgentFixtureProtocol.queue.reset([
                AgentFixture(text: "The image is red."), AgentFixture(text: "The earlier image stays red."),
            ])
            let markdown =
                "# Image note\n\nBefore ![diagram][figure] after.\n\n[figure]: pictures/shape.png\n\n```md\n![not an image](secret.png)\n```\n\n`![also not an image](private.png)`\n"
            let (_, bridge, _, url) = try await reader(markdown, api: api)
            let folder = url.deletingLastPathComponent().appendingPathComponent("pictures")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func pixels(_ color: UIColor) -> Data {
                UIGraphicsImageRenderer(size: CGSize(width: 160, height: 80)).pngData { context in
                    color.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 160, height: 80))
                }
            }
            try pixels(.red).write(to: folder.appendingPathComponent("shape.png"))
            _ = try await bridge.call("reloadResources")
            let capturedReference = try await bridge.call("imageContext", arguments: ["payload": 0])
            let reference = try XCTUnwrap(capturedReference as? [String: Any])
            XCTAssertEqual((reference["images"] as? [[String: String]])?.count, 1)
            XCTAssertEqual((reference["images"] as? [[String: String]])?.first?["source"], "pictures/shape.png")
            _ = try await bridge.call("askImage", arguments: ["payload": reference])
            try await wait { (try await self.state(bridge))["referenceHTML"] as? String != nil }
            let quote = try await state(bridge)["referenceHTML"] as? String ?? ""
            XCTAssertTrue(quote.contains("<img"))
            try await send("What is shown?", bridge: bridge)
            try await completed(bridge)
            let first = try ModelWireFormat.object(AgentFixtureProtocol.queue.requests()[0])
            let transmitted = try XCTUnwrap(first[api == .responses ? "input" : "messages"] as? [[String: Any]])
            let parts = try XCTUnwrap(transmitted.last?["content"] as? [[String: Any]])
            XCTAssertEqual(
                parts.filter { $0["type"] as? String == (api == .responses ? "input_image" : "image_url") }.count, 1)
            let context = try ModelWireFormat.object(Data(XCTUnwrap(parts.first?["text"] as? String).utf8))
            let inventory = try XCTUnwrap((context["background"] as? [String: Any])?["images"] as? [[String: Any]])
            XCTAssertEqual(inventory.count, 1, "Image-looking code and unused paths must not become image tools")
            XCTAssertNil(first["tools"], "All selected pixels are already present; no image read tool is needed")
            let imageURL: String? =
                api == .responses
                ? parts.last?["image_url"] as? String : (parts.last?["image_url"] as? [String: String])?["url"]
            XCTAssertTrue(imageURL?.hasPrefix("data:image/png;base64,") == true)
            try pixels(.blue).write(to: folder.appendingPathComponent("shape.png"))
            try await send("What did the previous picture show?", bridge: bridge)
            try await completed(bridge, count: 4)
            let second = try ModelWireFormat.object(AgentFixtureProtocol.queue.requests()[1])
            let messages = try XCTUnwrap(second[api == .responses ? "input" : "messages"] as? [[String: Any]])
            let continuedParts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
            let continuedURL: String? =
                api == .responses
                ? continuedParts.last?["image_url"] as? String
                : (continuedParts.last?["image_url"] as? [String: String])?["url"]
            XCTAssertEqual(continuedURL, imageURL, "A later question must receive the original sent pixels")
            _ = try await bridge.webView.evaluateJavaScript(
                "document.querySelector('.mdv-message-reference summary').click()")
            let frozenQuote =
                try await bridge.webView.evaluateJavaScript(
                    "document.querySelector('.mdv-message-reference img').getAttribute('src')") as? String
            XCTAssertTrue(frozenQuote?.hasPrefix("jm-image:") == true)
            try await wait { (try await self.state(bridge))["turns"] as? [[String: Any]] != nil }
        }
    }

    func testGlobalImageToolLoadsOnlyTheRequestedPictureInPreview() async throws {
        for api in ModelAPIProtocol.allCases {
            AgentFixtureProtocol.queue.reset([
                AgentFixture(calls: [ModelToolCall(id: "read-picture", name: "read_image", arguments: "$first-image")]),
                AgentFixture(text: "One requested picture was read."),
            ])
            let markdown = "# Images\n\n![First](first.svg)\n\n![Do not load](missing.png)\n"
            let (session, bridge, _, url) = try await reader(markdown, api: api)
            let svg =
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"40\"><rect width=\"80\" height=\"40\" fill=\"red\"/></svg>"
            try Data(svg.utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("first.svg"))
            _ = try await bridge.call("toggleAgent")
            try await send("Read the first picture, leave the second one alone.", bridge: bridge)
            try await completed(bridge)
            let requests = AgentFixtureProtocol.queue.requests()
            XCTAssertEqual(
                requests.count, 2, "The model explicitly asks for one image, then receives its actual pixels")
            let initial = try ModelWireFormat.object(requests[0])
            let items = try XCTUnwrap(initial[api == .responses ? "input" : "messages"] as? [[String: Any]])
            XCTAssertTrue(
                items.last?["content"] is String, "Global entry sends the inventory without eagerly attaching pixels")
            let tools = try XCTUnwrap(initial["tools"] as? [[String: Any]])
            let names = tools.compactMap {
                (api == .responses ? $0 : $0["function"] as? [String: Any] ?? [:])["name"] as? String
            }
            XCTAssertEqual(names, ["read_image"], "Preview must never offer document edit tools")
            let subsequent = try ModelWireFormat.object(requests[1])
            let subsequentItems = try XCTUnwrap(
                subsequent[api == .responses ? "input" : "messages"] as? [[String: Any]])
            let imageParts =
                api == .responses
                ? (subsequentItems.first { $0["type"] as? String == "function_call_output" })?["output"]
                    as? [[String: Any]]
                : subsequentItems.last?["content"] as? [[String: Any]]
            let picture = try XCTUnwrap(imageParts?.last)
            let imageURL: String? =
                api == .responses
                ? picture["image_url"] as? String : (picture["image_url"] as? [String: String])?["url"]
            XCTAssertTrue(imageURL?.hasPrefix("data:image/png;base64,") == true)
            XCTAssertEqual(session.agentImages.loadedIDs.count, 1)
            XCTAssertEqual(session.document?.text, markdown)
        }
    }

    func testMixedTextAndImageSelectionPreservesBothAndSourceReferenceImagesResolve() async throws {
        AgentFixtureProtocol.queue.reset([
            AgentFixture(text: "Mixed quote read."), AgentFixture(text: "Source image read."),
        ])
        let markdown =
            "# Note\n\nBefore ![diagram][figure] after.\n\n[figure]: picture.png\n\n```md\n![code-only](private.png)\n```\n"
        let (_, bridge, _, url) = try await reader(markdown, api: .responses)
        let pixels = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        try pixels.write(to: url.deletingLastPathComponent().appendingPathComponent("picture.png"))
        _ = try await bridge.webView.evaluateJavaScript(
            "const range=document.createRange(); range.selectNodeContents(document.querySelector('.mdv-article p')); getSelection().removeAllRanges(); getSelection().addRange(range);"
        )
        _ = try await bridge.call("askSelection")
        var quote = try await state(bridge)["referenceHTML"] as? String ?? ""
        XCTAssertTrue(quote.contains("Before"))
        XCTAssertTrue(quote.contains("after."))
        XCTAssertTrue(quote.contains("<img"))
        try await send("Explain the quote.", bridge: bridge)
        try await completed(bridge)
        _ = try await bridge.call("closeAgent")
        try await wait { !bridge.session.agentModalActive }
        try await sourceMode(bridge)
        try selectSource("![diagram][figure]", bridge: bridge)
        _ = try await bridge.call("askSelection")
        quote = try await state(bridge)["referenceHTML"] as? String ?? ""
        XCTAssertTrue(
            quote.contains("<img"), "Reference-style source images use definitions from the complete document")
        try await send("Read this image.", bridge: bridge)
        try await completed(bridge, count: 4)
        let requests = AgentFixtureProtocol.queue.requests()
        for request in requests {
            let body = try ModelWireFormat.object(request)
            let items = try XCTUnwrap(body["input"] as? [[String: Any]])
            XCTAssertTrue(
                (items.last?["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "input_image" }
                    == true)
        }
    }

    func testImageMenuActionUsesCapturedReferenceAndRejectsAStaleMode() async throws {
        AgentFixtureProtocol.queue.reset([])
        let (session, bridge, _, _) = try await reader("# Pictures\n\n![Diagram](diagram.svg)\n")
        let actionCount =
            try await bridge.webView.evaluateJavaScript(
                "document.querySelectorAll('.mdv-article .jm-image-action').length") as? Int
        XCTAssertEqual(actionCount, 1)
        let payload = try await bridge.call("imageContext", arguments: ["payload": 0])
        let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(payload))
        let reference = try JSONDecoder().decode(AgentAttachment.self, from: data)
        let host = try XCTUnwrap(bridge.imageMenu)
        let interaction = try XCTUnwrap(
            bridge.webView.subviews.flatMap(\.interactions).compactMap { $0 as? UIEditMenuInteraction }
                .first { $0.delegate === host })
        let menuView = try XCTUnwrap(interaction.view)
        XCTAssertTrue(menuView.superview === bridge.webView)
        XCTAssertFalse(menuView.isUserInteractionEnabled, "The AI menu host must leave image gestures to WebKit")
        XCTAssertFalse(bridge.webView.interactions.contains { $0 === interaction })
        func action(_ id: String) throws -> UIAction {
            let config = UIEditMenuConfiguration(identifier: id as NSString, sourcePoint: CGPoint(x: 50, y: 100))
            host.show(id: id, token: session.documentToken, reference: reference, point: config.sourcePoint)
            return try XCTUnwrap(
                host.editMenuInteraction(interaction, menuFor: config, suggestedActions: [])?.children.first
                    as? UIAction)
        }
        let first = try action("captured-image")
        let button = UIButton()
        button.addAction(first, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        try await wait { (try await self.state(bridge))["open"] as? Bool == true }
        let quote = try await state(bridge)["referenceHTML"] as? String ?? ""
        XCTAssertTrue(quote.contains("diagram.svg"))
        XCTAssertTrue(quote.contains("<img"))
        _ = try await bridge.call("closeAgent")
        try await wait { !session.agentModalActive }
        let stale = try action("old-mode")
        try await sourceMode(bridge)
        let oldButton = UIButton()
        oldButton.addAction(stale, for: .touchUpInside)
        oldButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(
            session.agentOpen, "A dismissed image menu must not reopen an old preview reference in source mode")
        XCTAssertEqual(
            AgentFixtureProtocol.queue.requests().count, 0, "Showing and choosing the menu never sends a model request")
        host.detach()
        XCTAssertNil(interaction.view)
        XCTAssertNil(menuView.superview)
    }

    func testSourceImageSyntaxInsideCodeDoesNotAttachPixels() async throws {
        AgentFixtureProtocol.queue.reset([
            AgentFixture(text: "Code."), AgentFixture(text: "Code."), AgentFixture(text: "Code."),
        ])
        let markdown =
            "# Examples\n\n![Real](same.png)\n\n`![Inline](same.png)`\n\n```md\n![Fence](same.png)\n```\n\n    ![Indented](same.png)\n"
        let (_, bridge, _, _) = try await reader(markdown, api: .responses)
        try await sourceMode(bridge)
        for (index, literal) in ["![Inline](same.png)", "![Fence](same.png)", "![Indented](same.png)"].enumerated() {
            try selectSource(literal, bridge: bridge)
            _ = try await bridge.call("askSelection")
            let quote = try await state(bridge)["referenceHTML"] as? String ?? ""
            XCTAssertTrue(quote.contains("<code"))
            XCTAssertFalse(
                quote.contains("<img"),
                "Image-looking code is literal text even when its URL also appears as a real image")
            try await send("Explain this code.", bridge: bridge)
            try await completed(bridge, count: (index + 1) * 2)
            _ = try await bridge.call("closeAgent")
            try await wait { !bridge.session.agentModalActive }
        }
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 3)
        for request in AgentFixtureProtocol.queue.requests() {
            let body = try ModelWireFormat.object(request)
            let items = try XCTUnwrap(body["input"] as? [[String: Any]])
            XCTAssertTrue(items.last?["content"] is String, "No code example may trigger eager image reads")
        }
    }

}
