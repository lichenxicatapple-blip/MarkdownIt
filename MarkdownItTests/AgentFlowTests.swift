import Combine
import UIKit
import WebKit
import XCTest

@testable import MarkdownIt

private struct AgentFixture: Sendable {
    var status = 200
    var text = ""
    var chunks: [String] = []
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
                if instructions.hasPrefix("你只负责整理对话材料") { return summaryFixture }
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
        if request.httpMethod == "GET", request.url?.path.hasSuffix("/models") == true {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"data":[{"id":"fixture-model","context_window":32768}]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
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
                let chunks = fixture.chunks.isEmpty ? [fixture.text] : fixture.chunks
                for (index, chunk) in chunks.enumerated() {
                    let payload: [String: Any] =
                        responses
                        ? ["type": "response.output_text.delta", "delta": chunk]
                        : ["choices": [["delta": ["content": chunk]]]]
                    let json = try! JSONSerialization.data(withJSONObject: payload)
                    var data = Data("data: ".utf8)
                    data.append(json)
                    data.append(Data("\n\n".utf8))
                    if fixture.complete && index == chunks.count - 1 {
                        data.append(
                            Data(
                                (responses
                                    ? "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n"
                                    : "data: [DONE]\n\n").utf8))
                    }
                    client?.urlProtocol(self, didLoad: data)
                }
                if fixture.waitsAfterText { return }
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

@MainActor
final class AgentFlowTests: AgentReaderTestCase {
    private let cjkMarkdown = #"""
        **Merger Mixed Consideration（混合对价合并）**就是一种合并方式。

        再用**CIL（零碎股现金替代）**支付，**cost basis（计税成本）**经调整后转移。

        同时触发**持仓系统（数量+成本）、主数据（价格）、期权系统（合约数）**三条线更新。

        **日本語。**続き。**한국어。**다음。

        *强调（斜体）*后续，~~旧值（删除）~~改为新值。

        字面标记 \*\*保留（符号）\*\*文本；English **Latin (term)**next；word_with_underscores。

        行内代码 `**CIL（零碎股现金替代）**支付`，以及公式 $x^2$。

        ```text
        **cost basis（计税成本）**经调整
        ```
        """#

    private let cjkBold = [
        "Merger Mixed Consideration（混合对价合并）", "CIL（零碎股现金替代）", "cost basis（计税成本）",
        "持仓系统（数量+成本）、主数据（价格）、期权系统（合约数）", "日本語。", "한국어。",
    ]

    private func assertCJKFormatting(_ selector: String, bridge: ReaderBridge) async throws {
        let result =
            try await (selector.hasPrefix(".mdv-article") ? bridge.webView : bridge.conversationWebView)
            .callAsyncJavaScript(
                """
                const content = document.querySelector(selector);
                const texts = tag => [...content.querySelectorAll(tag)].map(node => node.textContent);
                return {strong:texts('strong'), em:texts('em'), del:texts('s,del'), code:texts('code'),
                  text:content.textContent};
                """, arguments: ["selector": selector], in: nil, contentWorld: .page) as? [String: Any]
        let value = try XCTUnwrap(result)
        XCTAssertEqual(value["strong"] as? [String], cjkBold, selector)
        XCTAssertEqual(value["em"] as? [String], ["强调（斜体）"], selector)
        XCTAssertEqual(value["del"] as? [String], ["旧值（删除）"], selector)
        let code = try XCTUnwrap(value["code"] as? [String])
        XCTAssertEqual(code.count, 2)
        XCTAssertEqual(code.first, "**CIL（零碎股现金替代）**支付")
        // Captured preview HTML retains the source fence inside its code snapshot.
        let block = try XCTUnwrap(code.last)
        XCTAssertTrue(
            ["**cost basis（计税成本）**经调整\n", "```text\n**cost basis（计税成本）**经调整\n```"].contains(block))
        let text = try XCTUnwrap(value["text"] as? String)
        XCTAssertTrue(text.contains("**保留（符号）**文本"))
        XCTAssertTrue(text.contains("**Latin (term)**next"))
        XCTAssertTrue(text.contains("word_with_underscores"))
    }

    func testDocumentElasticOverscrollCannotMoveConversationChrome() async throws {
        let (_, bridge, window, _) = try await reader("# Reading\n\n" + String(repeating: "A passage.\n\n", count: 100))
        _ = try await bridge.call("toggleAgent")
        try await wait { bridge.session.agentOpen && !bridge.conversationPanel.isHidden }
        let panel = bridge.conversationPanel!
        try await wait { panel.layer.animationKeys()?.isEmpty != false && panel.bounds.height > 0 }
        window.endEditing(true)
        try await wait { bridge.webView.inputBottomInset == 0 }
        let targets: [UIView] = [panel, panel.clearButton, panel.collapseButton, panel.composer.view, panel.sendButton]
        let initial = targets.map { $0.convert($0.bounds, to: window) }
        let original = bridge.webView.scrollView.contentOffset
        defer { bridge.webView.scrollView.setContentOffset(original, animated: false) }
        for offset in [-40.0, -100.0, -160.0, 0.0] {
            bridge.webView.scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            _ = try await bridge.webView.callAsyncJavaScript(
                "for(let i=0;i<4;i++)await new Promise(requestAnimationFrame);", arguments: [:], in: nil,
                contentWorld: .page)
            for (view, frame) in zip(targets, initial) {
                XCTAssertEqual(
                    view.convert(view.bounds, to: window), frame, "Document rubber banding must not move panel chrome")
            }
            XCTAssertTrue(panel.composer.view.isDescendant(of: panel))
            XCTAssertTrue(panel.clearButton.isDescendant(of: panel))
            XCTAssertFalse(panel.isDescendant(of: bridge.webView))
            XCTAssertTrue(bridge.conversationWebView.isDescendant(of: panel))
        }
        recordWindow("native-conversation-at-document-boundary", window: window, rect: window.bounds)
    }

    func testReloadingConversationContentKeepsNativePresentationInteractive() async throws {
        let text = "A reading passage."
        let (session, bridge, _, _) = try await reader(text)
        bridge.webView.workspace.request("agent", open: true)
        try await wait {
            session.agentOpen && !bridge.conversationPanel.isHidden
                && bridge.conversationPanel.layer.animationKeys()?.isEmpty != false
        }
        let captured = try await bridge.call("captureRecovery")
        let saved = try XCTUnwrap(captured as? [String: Any])
        _ = try await bridge.call(
            "openDocument",
            arguments: [
                "payload": [
                    "token": session.documentToken, "name": "reading.md", "text": text, "recovery": saved,
                ]
            ])
        XCTAssertTrue(session.agentOpen)
        let inert =
            try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelector('.mdv-agent').inert") as? Bool
        XCTAssertEqual(inert, false, "Reloaded content must receive the current native presentation")
    }

    func testCJKEmphasisIsSharedByPreviewReferencesAndConversation() async throws {
        for api in ModelAPIProtocol.allCases {
            AgentFixtureProtocol.queue.reset([AgentFixture(text: cjkMarkdown)])
            let (session, bridge, _, _) = try await reader(cjkMarkdown, api: api)
            try await assertCJKFormatting(".mdv-article", bridge: bridge)
            _ = try await bridge.webView.evaluateJavaScript(
                """
                (() => { const range = document.createRange();
                  range.selectNodeContents(document.querySelector('.mdv-article'));
                  getSelection().removeAllRanges(); getSelection().addRange(range); })()
                """)
            _ = try await bridge.call("askSelection")
            try await wait { session.agentOpen }
            try await assertCJKFormatting(".mdv-composer-reference .mdv-rich-text", bridge: bridge)
            try await sourceMode(bridge)
            try selectSource(cjkMarkdown, bridge: bridge)
            _ = try await bridge.call("askSelection")
            try await assertCJKFormatting(".mdv-composer-reference .mdv-rich-text", bridge: bridge)
            try await send("解释**术语（示例）**含义。", bridge: bridge)
            try await completed(bridge)
            try await assertCJKFormatting(".mdv-assistant-turn > .mdv-rich-text", bridge: bridge)
            let questionBold =
                try await bridge.conversationWebView.evaluateJavaScript(
                    "document.querySelector('.mdv-user-turn > .mdv-rich-text strong')?.textContent") as? String
            XCTAssertEqual(questionBold, "术语（示例）")
            let captured = try await bridge.call("captureRecovery")
            let saved = try XCTUnwrap(captured as? [String: Any])
            _ = try await bridge.call(
                "openDocument",
                arguments: [
                    "payload": [
                        "token": session.documentToken, "name": "cjk.md", "text": cjkMarkdown, "recovery": saved,
                    ]
                ])
            try await assertCJKFormatting(".mdv-assistant-turn > .mdv-rich-text", bridge: bridge)
            XCTAssertEqual(
                AgentFixtureProtocol.queue.requests().count, 1, "Restoring must only render the stored answer")
            XCTAssertEqual(session.document?.text, cjkMarkdown)
        }
    }

    func testCodeCopyWorksInQuotesStreamingAndRestoredConversations() async throws {
        let code = "let message = \"你好 👋\"\nprint(message)\n"
        let markdown =
            "# Notes\n\n- Example:\n\n  ```swift\n  "
            + code.replacingOccurrences(of: "\n", with: "\n  ") + "```\n"
        let reply = "let answer = \"回答\"\nprint(answer)\n"
        AgentFixtureProtocol.queue.reset([
            AgentFixture(
                chunks: ["```swift\nlet answer = ", "\"回答\"\nprint(answer)\n```"], waitsAfterText: true, complete: false
            )
        ])
        let pasteboard = isolatedPasteboard()
        let (session, bridge, _, _) = try await reader(markdown, pasteboard: pasteboard)
        _ = try await bridge.webView.evaluateJavaScript(
            """
            (() => {
              const range=document.createRange();range.selectNodeContents(document.querySelector('.mdv-article ul'));
              getSelection().removeAllRanges();getSelection().addRange(range);
            })()
            """)
        _ = try await bridge.call("askSelection")
        try await wait { session.agentOpen }
        func copy(_ selector: String, expected: String) async throws {
            pasteboard.string = nil
            let found =
                try await bridge.conversationWebView.callAsyncJavaScript(
                    "const button=document.querySelector(selector);button?.click();return !!button;",
                    arguments: ["selector": selector], in: nil, contentWorld: .page) as? Bool
            XCTAssertEqual(found, true, selector)
            try await wait {
                try await bridge.conversationWebView.callAsyncJavaScript(
                    "return document.querySelector(selector)?.dataset.copied === 'true';",
                    arguments: ["selector": selector], in: nil, contentWorld: .page) as? Bool == true
            }
            XCTAssertEqual(pasteboard.string, expected)
        }
        try await copy(".mdv-composer-reference .mdv-code-copy", expected: code)
        let recoveryValue = try await bridge.call("captureRecovery")
        let captured = try XCTUnwrap(recoveryValue as? [String: Any])
        let conversation = try XCTUnwrap(captured["conversation"] as? [String: Any])
        let attachment = try XCTUnwrap(conversation["attachment"] as? [String: Any])
        let quote = try XCTUnwrap(attachment["markdown"] as? String)
        for chrome in ["<button", "<svg", "data:image", "mdv-code-"] {
            XCTAssertFalse(quote.contains(chrome), "Quoted source must exclude rendering controls: \(chrome)")
        }
        try await send("Show a code example.", bridge: bridge)
        try await wait {
            try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelector('.mdv-assistant-turn[data-state=streaming] pre code')?.textContent === 'let answer = \"回答\"\\nprint(answer)\\n'"
            ) as? Bool == true
        }
        try await copy(".mdv-assistant-turn .mdv-code-copy", expected: reply)
        try await copy(".mdv-message-reference > summary .mdv-code-copy", expected: code)
        let collapsed =
            try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelector('.mdv-message-reference > summary').getAttribute('aria-expanded')") as? String
        XCTAssertEqual(collapsed, "false", "Copying code must not toggle its enclosing reference")
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-message-reference > summary').click()")
        try await copy(".mdv-message-reference > .mdv-rich-text .mdv-code-copy", expected: code)
        _ = try await bridge.conversationWebView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
        try await wait { session.agentTransport.activeID == nil }
        let savedValue = try await bridge.call("captureRecovery")
        let recovery = try XCTUnwrap(savedValue as? [String: Any])
        _ = try await bridge.call(
            "openDocument",
            arguments: [
                "payload": ["token": session.documentToken, "name": "notes.md", "text": markdown, "recovery": recovery]
            ])
        try await copy(".mdv-assistant-turn .mdv-code-copy", expected: reply)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 1)
        XCTAssertEqual(session.document?.text, markdown)
    }

    func testFragmentedCJKRepliesPreserveFormattingWhileStreamingAndAfterStop() async throws {
        let chunks = ["**CIL（零碎股现金", "替代）*", "*支付。\n\n", "*中文（斜体）", "*后续，~~旧值（删除）~", "~改为新值。"]
        for api in ModelAPIProtocol.allCases {
            AgentFixtureProtocol.queue.reset([AgentFixture(chunks: chunks, waitsAfterText: true, complete: false)])
            let (session, bridge, _, _) = try await reader("# 文档\n\n正文。", api: api)
            _ = try await bridge.call("toggleAgent")
            try await send("解释", bridge: bridge)
            try await wait {
                try await bridge.conversationWebView.evaluateJavaScript(
                    "document.querySelector('.mdv-assistant-turn[data-state=streaming] :is(s,del)')?.textContent === '旧值（删除）'"
                )
                    as? Bool == true
            }
            _ = try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelector('.mdv-agent-send').click()")
            try await wait { session.agentTransport.activeID == nil }
            let result =
                try await bridge.conversationWebView.evaluateJavaScript(
                    """
                    (() => { const turn = document.querySelector('.mdv-assistant-turn');
                      return {strong:turn.querySelector('strong')?.textContent, em:turn.querySelector('em')?.textContent,
                        del:turn.querySelector('s,del')?.textContent, state:turn.dataset.state}; })()
                    """) as? [String: String]
            XCTAssertEqual(result?["strong"], "CIL（零碎股现金替代）")
            XCTAssertEqual(result?["em"], "中文（斜体）")
            XCTAssertEqual(result?["del"], "旧值（删除）")
            XCTAssertEqual(result?["state"], "stopped")
        }
    }

    func testRecoveryKeepsPartialAnswerDraftAndRetryWithoutAnAutomaticRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        let store = ReaderRecoveryStore(directory: directory)
        AgentFixtureProtocol.queue.reset([
            AgentFixture(text: "Partial **answer**.", waitsAfterText: true, complete: false)
        ])
        let (session, bridge, _, _) = try await reader("# Document\n\nContent.\n", recoveryStore: store)
        _ = try await bridge.call("toggleAgent")
        try await send("Explain the document", bridge: bridge)
        try await wait {
            let turns = try await self.state(bridge)["turns"] as? [[String: Any]]
            return turns?.last?["state"] as? String == "streaming"
        }
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-composer textarea').value = 'Follow-up draft';")
        try await wait { bridge.composer.checkpoint()?.text == "Follow-up draft" }
        await session.checkpointForBackground()
        let requests = AgentFixtureProtocol.queue.requests().count
        session.agentTransport.cancel()
        bridge.detach()
        _ = await session.document?.closeSavingChanges()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentFixtureProtocol.self]
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set("https://agent.example.test/v1", forKey: "model.baseURL")
        defaults.set("fixture-model", forKey: "model.id")
        defaults.set(ModelAPIProtocol.chatCompletions.rawValue, forKey: "model.apiProtocol")
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let next = ReaderSession(
            defaults: defaults,
            modelClient: ModelClient(session: URLSession(configuration: configuration)),
            modelCatalog: ModelCatalog(session: URLSession(configuration: configuration)), modelKey: { "fixture-key" },
            modelSettings: isolatedModelSettings(), recoveryStore: ReaderRecoveryStore(directory: directory))
        addTeardownBlock { @MainActor in await next.closeDocument() }
        await next.restoreLastSession()
        let (restored, _) = try await mountReader(next)
        try await wait { next.agentOpen && restored.composer.checkpoint()?.text == "Follow-up draft" }
        let status = try await state(restored)
        let turns = try XCTUnwrap(status["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns.last?["state"] as? String, "failed")
        let answer = try await restored.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-assistant-turn .mdv-rich-text').textContent")
        XCTAssertTrue((answer as? String)?.contains("Partial answer.") == true)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, requests, "Restoration must not send an AI request")
        next.dataConsent.allow(try ModelDataConsent.service(for: next.configuration))
        AgentFixtureProtocol.queue.reset([AgentFixture(text: "Complete answer.")])
        _ = try await restored.conversationWebView.evaluateJavaScript(
            "document.querySelector('[data-agent-action=retry]').click()")
        try await completed(restored)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 1)
        XCTAssertEqual(restored.composer.checkpoint()?.text, "Follow-up draft")
    }

    func testConversationSurvivesModesReaderCloseAndReopenUntilUserClearsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        let conversations = AgentConversationStore(directory: directory.appendingPathComponent("Conversations"))
        let recovery = ReaderRecoveryStore(directory: directory.appendingPathComponent("Recovery"))
        AgentFixtureProtocol.queue.reset([AgentFixture(text: "A retained **answer**.")])
        let (session, bridge, _, url) = try await reader(
            "# A document\n\nA quoted passage.\n", recoveryStore: recovery, conversationStore: conversations)
        _ = try await bridge.call("toggleAgent")
        try await send("Explain this passage", bridge: bridge)
        try await completed(bridge)
        _ = try await bridge.call("askSelection", arguments: ["payload": "A quoted passage."])
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-composer textarea').value='An unsent follow-up';")
        try await wait { bridge.composer.checkpoint()?.text == "An unsent follow-up" }
        let contextID = session.conversationID
        let token = session.documentToken
        for expected in ["source", "preview", "source"] {
            session.toggleMode()
            try await wait {
                let mode = (try await bridge.call("diagnostics") as? [String: Any])?["mode"] as? String
                let transitioning =
                    try await bridge.webView.evaluateJavaScript(
                        "Boolean(document.querySelector('.mdv-app').dataset.modeTransition)") as? Bool
                return mode == expected && transitioning == false
            }
            let modeState = try await state(bridge)
            XCTAssertEqual((modeState["turns"] as? [[String: Any]])?.count, 2)
            XCTAssertEqual(bridge.composer.checkpoint()?.text, "An unsent follow-up")
        }
        await session.checkpointRecovery()
        bridge.webViewWebContentProcessDidTerminate(bridge.webView)
        try await wait { session.rendererReady && bridge.composer.checkpoint()?.text == "An unsent follow-up" }
        let reloaded = try await state(bridge)
        XCTAssertEqual((reloaded["turns"] as? [[String: Any]])?.count, 2)
        bridge.composer.focus("question")
        try await wait { bridge.composer.view.isFirstResponder }
        await session.closeDocument()
        XCTAssertNil(session.document)
        let closedRecovery = try await recovery.load()
        XCTAssertNil(closedRecovery, "Closing must end launch auto-resume without deleting AI history")
        var teardownPublications = 0
        let observation = session.objectWillChange.sink { teardownPublications += 1 }
        bridge.detach()
        XCTAssertEqual(teardownPublications, 0, "Removing focused controls must not republish a closed reader")
        XCTAssertFalse(session.agentOpen)
        XCTAssertFalse(session.agentVisible)
        observation.cancel()
        await session.open(url)
        let (reopened, _) = try await mountReader(session)
        XCTAssertNotEqual(session.documentToken, token, "Reopening must reject callbacks from the previous reader")
        XCTAssertEqual(session.conversationID, contextID)
        let restoredValue = try await reopened.call("captureRecovery") as? [String: Any]
        let restoredConversation = restoredValue?["conversation"] as? [String: Any]
        XCTAssertEqual(
            (restoredConversation?["attachment"] as? [String: Any])?["text"] as? String, "A quoted passage.")
        _ = try await reopened.call("toggleAgent")
        try await wait { reopened.composer.checkpoint()?.text == "An unsent follow-up" }
        let value = try await state(reopened)
        XCTAssertEqual((value["turns"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(value["reference"] as? String, "")
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 1, "Reopening must not issue a model request")
        session.requestAgentHistoryClear(token: session.documentToken)
        session.finishAgentHistoryClear(confirmed: true)
        try await wait { (try await self.state(reopened)["turns"] as? [[String: Any]])?.isEmpty == true }
        await session.closeDocument()
        reopened.detach()
        await session.open(url)
        let (cleared, _) = try await mountReader(session)
        _ = try await cleared.call("toggleAgent")
        try await wait { cleared.composer.checkpoint()?.text == "An unsent follow-up" }
        let clearedState = try await state(cleared)
        XCTAssertTrue((clearedState["turns"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 1)
    }

    func testClosedConversationsStayIsolatedByPathAcrossNewSessions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        let conversations = directory.appendingPathComponent("Conversations")
        let recovery = directory.appendingPathComponent("Recovery")
        AgentFixtureProtocol.queue.reset([AgentFixture(text: "The first document's answer.")])
        let (session, bridge, _, url) = try await reader(
            "# First\n", recoveryStore: ReaderRecoveryStore(directory: recovery),
            conversationStore: AgentConversationStore(directory: conversations))
        _ = try await bridge.call("toggleAgent")
        try await send("Keep this history", bridge: bridge)
        try await completed(bridge)
        await session.closeDocument()
        bridge.detach()
        let other = url.deletingLastPathComponent().appendingPathComponent("Other", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
        try FileManager.default.createDirectory(
            at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Same name, another document\n".utf8).write(to: other)
        await session.open(other)
        let (otherBridge, _) = try await mountReader(session)
        let otherState = try await state(otherBridge)
        XCTAssertTrue((otherState["turns"] as? [[String: Any]])?.isEmpty == true)
        await session.closeDocument()
        otherBridge.detach()
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let next = ReaderSession(
            defaults: defaults, modelSettings: isolatedModelSettings(),
            recoveryStore: ReaderRecoveryStore(directory: recovery),
            annotationStore: ReadingAnnotationStore(directory: directory.appendingPathComponent("Annotations")),
            conversationStore: AgentConversationStore(directory: conversations))
        addTeardownBlock { @MainActor in await next.closeDocument() }
        await next.restoreLastSession()
        XCTAssertNil(next.document, "An explicit close must continue to launch at home")
        await next.open(url)
        let (restored, _) = try await mountReader(next)
        let value = try await state(restored)
        let turns = try XCTUnwrap(value["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 2)
        XCTAssertTrue((turns.last?["text"] as? String)?.contains("The first document's answer.") == true)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 1)
    }

    func testClearHistoryCannotBeUndoneByAnOlderReaderCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        let readerDirectory = directory.appendingPathComponent("Recovery")
        let conversationDirectory = directory.appendingPathComponent("Conversations")
        let store = ReaderRecoveryStore(directory: readerDirectory)
        AgentFixtureProtocol.queue.reset([AgentFixture(text: "An answer the user will delete.")])
        let (session, bridge, _, _) = try await reader(
            "# Document\n", recoveryStore: store,
            conversationStore: AgentConversationStore(directory: conversationDirectory))
        _ = try await bridge.call("toggleAgent")
        try await send("Explain", bridge: bridge)
        try await completed(bridge)
        await session.checkpointRecovery()
        let loaded = try await store.load()
        let old = try XCTUnwrap(loaded)
        session.requestAgentHistoryClear(token: session.documentToken)
        session.finishAgentHistoryClear(confirmed: true)
        try await wait { (try await self.state(bridge)["turns"] as? [[String: Any]])?.isEmpty == true }
        await session.checkpointRecovery()
        bridge.detach()
        _ = await session.document?.closeSavingChanges()
        // Simulate a reading checkpoint that did not reach disk after the independent AI save.
        try await ReaderRecoveryStore(directory: readerDirectory).save(old)
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let next = ReaderSession(
            defaults: defaults, modelSettings: isolatedModelSettings(),
            recoveryStore: ReaderRecoveryStore(directory: readerDirectory),
            annotationStore: ReadingAnnotationStore(directory: directory.appendingPathComponent("Annotations")),
            conversationStore: AgentConversationStore(directory: conversationDirectory))
        addTeardownBlock { @MainActor in await next.closeDocument() }
        await next.restoreLastSession()
        let (restored, _) = try await mountReader(next)
        let value = try await state(restored)
        XCTAssertTrue((value["turns"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertNil(next.agentTransport.recovery())
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 1)
    }

    func testCompletedEditIsNotReappliedAfterExplicitCloseAndRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        let original = "# Original\n"
        let arguments = try JSONSerialization.data(withJSONObject: [
            "revision": AgentDocumentTools.revision(original),
            "edits": [["before": "Original", "after": "Edited"]],
        ])
        let call = ModelToolCall(
            id: "durable-tool", name: "edit_document", arguments: String(decoding: arguments, as: UTF8.self))
        AgentFixtureProtocol.queue.reset([AgentFixture(calls: [call]), AgentFixture(status: 429)])
        let (session, bridge, _, url) = try await reader(
            original, recoveryStore: ReaderRecoveryStore(directory: directory.appendingPathComponent("Recovery")),
            conversationStore: AgentConversationStore(directory: directory.appendingPathComponent("Conversations")))
        try await sourceMode(bridge)
        _ = try await bridge.call("toggleAgent")
        try await send("Change the heading to Edited", bridge: bridge)
        try await wait {
            (try await self.state(bridge)["turns"] as? [[String: Any]])?.last?["state"] as? String == "failed"
        }
        XCTAssertEqual(session.document?.text, "# Edited\n")
        await session.closeDocument()
        bridge.detach()
        await session.open(url)
        let (restored, _) = try await mountReader(session)
        _ = try await restored.call("toggleAgent")
        AgentFixtureProtocol.queue.reset([AgentFixture(text: "The heading has been edited.")])
        _ = try await restored.conversationWebView.evaluateJavaScript(
            "document.querySelector('[data-agent-action=retry]').click()")
        try await completed(restored)
        XCTAssertEqual(session.document?.text, "# Edited\n")
        XCTAssertFalse(restored.sourceEditor.history.canUndo, "Retry must not create another document edit")
        let requests = AgentFixtureProtocol.queue.requests()
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests.first)
        let object = try ModelWireFormat.object(body)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == call.id })
    }

    func testClosingConversationWaitsForItsPresentationToFinish() async throws {
        let (session, bridge, _, _) = try await reader("# Document\n\nContent.\n")
        _ = try await bridge.call("toggleAgent")
        try await wait { session.agentOpen }
        let acknowledged = await session.closeAgent()
        XCTAssertTrue(acknowledged)
        XCTAssertTrue(bridge.conversationPanel.isHidden, "Closing acknowledges the completed native transition")
        XCTAssertFalse(bridge.conversationPanel.isUserInteractionEnabled)
        XCTAssertNil(bridge.conversationPanel.layer.animationKeys())
        XCTAssertFalse(session.agentModalActive)
    }

    func testReopeningConversationCancelsPendingCloseAcknowledgement() async throws {
        let (session, bridge, _, _) = try await reader("# Document\n\nContent.\n")
        _ = try await bridge.call("toggleAgent")
        try await wait { session.agentOpen }
        let closing = Task { await session.closeAgent() }
        await Task.yield()
        bridge.webView.workspace.request("agent", open: true)
        let acknowledged = await closing.value
        XCTAssertEqual(acknowledged, false)
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
            _ = try await session.modelCatalog.models(baseURL: session.configuration.baseURL, key: "fixture-key")
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
            let recovery = try XCTUnwrap(session.agentTransport.recovery())
            XCTAssertNotNil(recovery.context?.summary)
            try session.agentTransport.restore(
                JSONDecoder().decode(AgentModelTransport.Recovery.self, from: JSONEncoder().encode(recovery)))
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
                arguments: #"{"documentID":null,"characterOffset":null,"query":"EXACT_END_TARGET"}"#)
            AgentFixtureProtocol.queue.reset([
                AgentFixture(calls: [call]), AgentFixture(text: "The ending says EXACT_END_TARGET."),
            ])
            let (session, bridge, _, _) = try await reader(text, api: api)
            _ = try await session.modelCatalog.models(baseURL: session.configuration.baseURL, key: "fixture-key")
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
            XCTAssertEqual(names, ["get_current_time", "read_document"])
            XCTAssertLessThan(requests[0].count, 20_000)
            let continuation = String(decoding: requests[1], as: UTF8.self)
            XCTAssertTrue(continuation.contains("EXACT_END_TARGET"))
            XCTAssertTrue(continuation.contains("precedingContentOmitted"))
            XCTAssertEqual(session.mode, "preview")
            XCTAssertEqual(session.document?.text, text)
        }
    }

    func testCurrentFileAndSnapshotReadsShareCharacterCoordinates() async throws {
        AgentFixtureProtocol.queue.reset([])
        let fileText = "😀中文e\u{301}🇨🇳👨‍👩‍👧‍👦\r\n" + String(repeating: "Résumé 文档。\r\n", count: 20)
        let (session, _, _, url) = try await reader(fileText)
        let text = try XCTUnwrap(session.document?.text)
        let tools = AgentDocumentTools(session: session)
        let doc = AgentAttachment(
            text: text, markdown: text, mode: "preview", scope: "document", location: nil, start: nil, end: nil)
        let sources = AgentContextSources(.init(question: "Read", attachment: nil, history: [], document: doc))
        for offset in [0, 1, 2, 3, 4, 5, 6, text.count - 2, text.count] {
            func call(documentID: String?) throws -> ModelToolCall {
                let data = try JSONSerialization.data(withJSONObject: [
                    "documentID": documentID as Any? ?? NSNull(), "characterOffset": offset, "query": NSNull(),
                ])
                return .init(
                    id: UUID().uuidString, name: "read_document", arguments: String(decoding: data, as: UTF8.self))
            }
            let current = await tools.execute(
                try call(documentID: nil), token: session.documentToken, maxReadBytes: 64)
            let saved = try XCTUnwrap(sources.read(try call(documentID: AgentContextSources.id(text)), maxBytes: 64))
            let live = try ModelWireFormat.object(Data(current.output.utf8))
            let snapshot = try ModelWireFormat.object(Data(saved.output.utf8))
            XCTAssertEqual(live as NSDictionary, snapshot as NSDictionary)
            XCTAssertEqual(live["characterOffset"] as? Int, offset)
            XCTAssertEqual(live["totalCharacters"] as? Int, text.count)
            XCTAssertTrue(text.dropFirst(offset).hasPrefix(live["content"] as? String ?? ""))
        }
        XCTAssertEqual(session.document?.text, text)
        XCTAssertFalse(session.document?.hasUnsavedChanges ?? true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), fileText)
        XCTAssertTrue(AgentFixtureProtocol.queue.requests().isEmpty)
        let schema = try ModelWireFormat.object(AgentDocumentTools.definitions[0].parameters)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["characterOffset"])
        XCTAssertNil(properties["offset"])
    }

    func testWebSearchResultsStayNativeAndRemainAvailableAfterRecoveryAndFollowup() async throws {
        let call = ModelToolCall(
            id: "search-first", name: "web_search", arguments: #"{"query":"公开资料","language":"zh-Hans"}"#)
        for api in ModelAPIProtocol.allCases {
            WebSearchFixture.state.reset()
            AgentFixtureProtocol.queue.reset([
                AgentFixture(calls: [call]),
                AgentFixture(text: "参考[公开来源](https://source.example.org/reading)。"),
                AgentFixture(text: "根据刚才取得的公开资料继续回答。"),
            ])
            let (session, bridge, _, _) = try await reader(
                "# 文档\n\nPRIVATE_DOCUMENT_CONTEXT\n", api: api, webSearchClient: WebSearchFixture.client())
            try session.saveConfiguration(
                session.configuration, key: session.apiKey,
                search: .init(provider: .serper, keys: ["serper": "search-secret-only"]))
            _ = try await bridge.call("toggleAgent")
            try await send("联网查阅公开资料", bridge: bridge)
            try await wait { session.searchAuthorization.request != nil }
            XCTAssertEqual(session.searchAuthorization.request?.provider, .serper)
            XCTAssertEqual(WebSearchFixture.state.captured().count, 0, "Permission must precede the network request")
            session.searchAuthorization.finish(allowed: true)
            try await completed(bridge)
            XCTAssertEqual(WebSearchFixture.state.captured().count, 1)
            let searchBody = String(
                decoding: try XCTUnwrap(WebSearchFixture.state.captured().first?.httpBody), as: UTF8.self)
            XCTAssertFalse(searchBody.contains("PRIVATE_DOCUMENT_CONTEXT"))
            XCTAssertFalse(searchBody.contains("fixture-key"))
            let requests = AgentFixtureProtocol.queue.requests()
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue(String(decoding: requests[0], as: UTF8.self).contains("web_search"))
            XCTAssertTrue(String(decoding: requests[1], as: UTF8.self).contains("Verified external information"))
            for request in requests {
                XCTAssertFalse(String(decoding: request, as: UTF8.self).contains("search-secret-only"))
            }
            let saved = try JSONEncoder().encode(XCTUnwrap(session.agentTransport.recovery()))
            XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("search-secret-only"))
            try session.agentTransport.restore(JSONDecoder().decode(AgentModelTransport.Recovery.self, from: saved))
            try await send("刚才的来源还说明了什么？", bridge: bridge)
            try await completed(bridge, count: 4)
            let followup = String(decoding: try XCTUnwrap(AgentFixtureProtocol.queue.requests().last), as: UTF8.self)
            XCTAssertTrue(followup.contains("searchResults"))
            XCTAssertTrue(followup.contains("Verified external information"))
            XCTAssertTrue(followup.contains("source.example.org"))
            XCTAssertEqual(WebSearchFixture.state.captured().count, 1)
            XCTAssertEqual(session.document?.text, "# 文档\n\nPRIVATE_DOCUMENT_CONTEXT\n")
        }
    }

    func testWebPageReadsPersistWithTheirTurnAndRemainAvailableAfterRelaunch() async throws {
        let call = ModelToolCall(
            id: "page-first", name: "read_webpage",
            arguments: #"{"url":"https://source.example.org/article","characterOffset":null,"query":null}"#)
        for api in ModelAPIProtocol.allCases {
            WebSearchFixture.state.reset(
                body: Data(#"{"text":"This is extracted webpage text.","metadata":{"title":"Public reading"}}"#.utf8))
            AgentFixtureProtocol.queue.reset([
                AgentFixture(calls: [call]), AgentFixture(text: "[来源](https://source.example.org/article)说明了这一点。"),
                AgentFixture(text: "根据刚才读到的正文继续回答。"),
            ])
            let (session, bridge, _, _) = try await reader(
                "# 文档\n\n请参考公开链接。", api: api, webSearchClient: WebSearchFixture.client())
            try session.saveConfiguration(
                session.configuration, key: session.apiKey,
                search: .init(provider: .serper, keys: ["serper": "page-secret-only"]))
            _ = try await bridge.call("toggleAgent")
            try await send("请阅读这个网页", bridge: bridge)
            try await wait { session.searchAuthorization.request != nil }
            XCTAssertEqual(session.searchAuthorization.request?.provider, .serper)
            session.searchAuthorization.finish(allowed: true)
            try await completed(bridge)
            XCTAssertEqual(WebSearchFixture.state.captured().first?.url?.host, "scrape.serper.dev")
            let recovery = try JSONEncoder().encode(XCTUnwrap(session.agentTransport.recovery()))
            XCTAssertFalse(String(decoding: recovery, as: UTF8.self).contains("page-secret-only"))
            try session.agentTransport.restore(JSONDecoder().decode(AgentModelTransport.Recovery.self, from: recovery))
            try await send("接着说明", bridge: bridge)
            try await completed(bridge, count: 4)
            let followup = String(decoding: try XCTUnwrap(AgentFixtureProtocol.queue.requests().last), as: UTF8.self)
            XCTAssertTrue(followup.contains("webPages"))
            XCTAssertTrue(followup.contains("This is extracted webpage text."))
            let request = try ModelWireFormat.object(Data(followup.utf8))
            let messages = try XCTUnwrap(request[api == .responses ? "input" : "messages"] as? [[String: Any]])
            let user = try XCTUnwrap(messages.first { $0["role"] as? String == "user" }?["content"] as? String)
            let materials = try ModelWireFormat.object(Data(user.utf8))
            let pages = try XCTUnwrap(materials["webPages"] as? [[String: Any]])
            XCTAssertEqual(pages.first?["url"] as? String, "https://source.example.org/article")
            XCTAssertEqual(WebSearchFixture.state.captured().count, 1)
            XCTAssertEqual(session.document?.text, "# 文档\n\n请参考公开链接。")
        }
    }

    func testUnconfiguredSearchHasNoToolOrNetworkAndDoesNotBlockReading() async throws {
        for api in ModelAPIProtocol.allCases {
            WebSearchFixture.state.reset()
            AgentFixtureProtocol.queue.reset([AgentFixture(text: "依据文档说明。")])
            let (session, bridge, _, _) = try await reader(
                "# 文档\n\n正文。\n", api: api, webSearchClient: WebSearchFixture.client())
            _ = try await bridge.call("toggleAgent")
            try await send("解释正文", bridge: bridge)
            try await completed(bridge)
            let body = try ModelWireFormat.object(XCTUnwrap(AgentFixtureProtocol.queue.requests().first))
            for tool in body["tools"] as? [[String: Any]] ?? [] {
                let name = tool["name"] as? String ?? (tool["function"] as? [String: Any])?["name"] as? String
                XCTAssertNotEqual(name, "web_search")
            }
            XCTAssertEqual(WebSearchFixture.state.captured().count, 0)
            XCTAssertNil(session.searchAuthorization.request)
            XCTAssertFalse(
                String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self).contains(
                    "searchSettings"))
        }
    }

    func testDecliningSearchRemovesTheToolForThisAnswerAndKeepsReadingAvailable() async throws {
        let call = ModelToolCall(
            id: "search-declined", name: "web_search", arguments: #"{"query":"public source","language":null}"#)
        WebSearchFixture.state.reset()
        AgentFixtureProtocol.queue.reset([AgentFixture(calls: [call]), AgentFixture(text: "根据已有文档回答。")])
        let (session, bridge, _, _) = try await reader(
            "# 文档\n\n正文。", api: .responses, webSearchClient: WebSearchFixture.client())
        try session.saveConfiguration(
            session.configuration, key: session.apiKey,
            search: .init(provider: .serper, keys: ["serper": "search-test-only"]))
        _ = try await bridge.call("toggleAgent")
        try await send("搜索相关资料", bridge: bridge)
        try await wait { session.searchAuthorization.request != nil }
        session.searchAuthorization.finish(allowed: false)
        try await completed(bridge)
        XCTAssertEqual(WebSearchFixture.state.captured().count, 0)
        XCTAssertNil(session.searchAuthorization.request)
        let continuation = try ModelWireFormat.object(XCTUnwrap(AgentFixtureProtocol.queue.requests().last))
        XCTAssertFalse(
            (continuation["tools"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "web_search" })
        XCTAssertTrue(
            String(decoding: try JSONSerialization.data(withJSONObject: continuation), as: UTF8.self).contains(
                "search_permission"))
    }

    func testRepeatedSearchReusesTheJournalWithoutAnotherPaidRequest() async throws {
        WebSearchFixture.state.reset()
        AgentFixtureProtocol.queue.reset([
            AgentFixture(calls: [
                .init(id: "search-once", name: "web_search", arguments: #"{"query":"public source","language":null}"#)
            ]),
            AgentFixture(calls: [
                .init(id: "search-again", name: "web_search", arguments: #"{"language":null,"query":"public source"}"#)
            ]),
            AgentFixture(text: "依据已取得的来源回答。"),
        ])
        let (session, bridge, _, _) = try await reader(
            "# 文档\n\n正文。", api: .responses, webSearchClient: WebSearchFixture.client())
        try session.saveConfiguration(
            session.configuration, key: session.apiKey,
            search: .init(provider: .serper, keys: ["serper": "search-test-only"]))
        _ = try await bridge.call("toggleAgent")
        try await send("搜索公开资料", bridge: bridge)
        try await wait { session.searchAuthorization.request != nil }
        session.searchAuthorization.finish(allowed: true)
        try await completed(bridge)
        XCTAssertEqual(WebSearchFixture.state.captured().count, 1)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 3)
        XCTAssertTrue(
            String(decoding: try XCTUnwrap(AgentFixtureProtocol.queue.requests().last), as: UTF8.self).contains(
                "repeated_without_progress"))
    }

    func testCurrentTimeIsAvailableInBothModesAndProtocols() async throws {
        for api in ModelAPIProtocol.allCases {
            for editing in [false, true] {
                AgentFixtureProtocol.queue.reset([
                    AgentFixture(calls: [.init(id: "clock", name: "get_current_time", arguments: "{}")]),
                    AgentFixture(text: "The current time has been read."),
                ])
                let (session, bridge, _, _) = try await reader("# Document\n\nContent.\n", api: api)
                if editing { try await sourceMode(bridge) }
                _ = try await bridge.call("toggleAgent")
                try await send("What is the current system time?", bridge: bridge)
                try await completed(bridge)
                let requests = AgentFixtureProtocol.queue.requests()
                XCTAssertEqual(requests.count, 2)
                let toolResult = String(decoding: try XCTUnwrap(requests.last), as: UTF8.self)
                XCTAssertTrue(toolResult.contains("currentTime"))
                XCTAssertTrue(toolResult.contains("timeZone"))
                XCTAssertEqual(session.document?.text, "# Document\n\nContent.\n")
            }
        }
    }

    func testClearHistoryCancelsGenerationAndKeepsDraftReferenceAndDocumentUndo() async throws {
        let original = "# Document\n\nSelected passage.\n"
        for api in ModelAPIProtocol.allCases {
            let arguments: [String: Any] = [
                "revision": AgentDocumentTools.revision(original),
                "edits": [["before": "Selected passage.", "after": "Revised passage."]],
            ]
            let call = ModelToolCall(
                id: "edit-before-clear", name: "edit_document",
                arguments: String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self))
            AgentFixtureProtocol.queue.reset([
                AgentFixture(calls: [call]),
                AgentFixture(text: "The passage is revised.", waitsAfterText: true, complete: false),
                AgentFixture(text: "This is a new conversation."),
            ])
            let (session, bridge, _, _) = try await reader(original, api: api)
            try await sourceMode(bridge)
            _ = try await bridge.call("toggleAgent")
            try await send("RETIRED_QUESTION: replace Selected passage. with Revised passage.", bridge: bridge)
            try await wait {
                (try await self.state(bridge)["turns"] as? [[String: Any]])?.last?["state"] as? String == "streaming"
            }
            try selectSource("Revised passage.", bridge: bridge)
            _ = try await bridge.call("askSelection")
            try await wait {
                (try await self.state(bridge)["reference"] as? String)?.contains("Revised passage.") == true
            }
            _ = try await bridge.conversationWebView.evaluateJavaScript(
                "const field=document.querySelector('.mdv-agent-input'); field.value='Unsent follow-up'; field.dispatchEvent(new Event('input',{bubbles:true}));"
            )
            bridge.conversationPanel.clearButton.sendActions(for: .touchUpInside)
            try await wait { session.needsAgentHistoryClear }
            session.finishAgentHistoryClear(confirmed: false)
            XCTAssertNotNil(session.agentTransport.activeID)
            let retained = try await state(bridge)
            XCTAssertEqual((retained["turns"] as? [[String: Any]])?.count, 2)

            bridge.conversationPanel.clearButton.sendActions(for: .touchUpInside)
            try await wait { session.needsAgentHistoryClear }
            session.finishAgentHistoryClear(confirmed: true)
            try await wait { (try await self.state(bridge)["turns"] as? [[String: Any]])?.isEmpty == true }
            let cleared = try await state(bridge)
            XCTAssertEqual(cleared["draft"] as? String, "Unsent follow-up")
            XCTAssertTrue((cleared["reference"] as? String)?.contains("Revised passage.") == true)
            XCTAssertEqual(cleared["open"] as? Bool, true)
            XCTAssertNil(session.agentTransport.activeID)
            XCTAssertNil(session.agentTransport.recovery())
            XCTAssertEqual(session.document?.text, original.replacingOccurrences(of: "Selected", with: "Revised"))
            XCTAssertTrue(bridge.sourceEditor.history.canUndo)

            try await send("Unsent follow-up", bridge: bridge)
            try await completed(bridge)
            let next = String(decoding: try XCTUnwrap(AgentFixtureProtocol.queue.requests().last), as: UTF8.self)
            XCTAssertFalse(next.contains("RETIRED_QUESTION"))
            session.performSourceHistory(forward: false)
            try await wait { session.document?.text == original }
        }
    }

    func testConversationControlsKeepSystemSymbolsAcrossMessageUpdates() async throws {
        AgentFixtureProtocol.queue.reset([
            AgentFixture(text: String(repeating: "First answer.\n\n", count: 64)), AgentFixture(text: "Second answer."),
        ])
        let (_, bridge, window, _) = try await reader("# Reading\n\nA passage to discuss.\n")
        _ = try await bridge.call("toggleAgent")
        for (index, question) in ["First question.", "Follow-up question."].enumerated() {
            try await send(question, bridge: bridge)
            try await completed(bridge, count: (index + 1) * 2)
            let controls = try XCTUnwrap(bridge.conversationPanel)
            let pixel = 1 / window.traitCollection.displayScale
            func settledGeometry() async throws -> [String: Double] {
                let values =
                    try await bridge.conversationWebView.evaluateJavaScript(
                        "(() => {const s=document.querySelector('.mdv-agent-scroll');return s.scrollHeight-s.clientHeight;})()"
                    ) as? Double
                let panel = controls.convert(controls.bounds, to: bridge.webView)
                let button = controls.collapseButton.convert(controls.collapseButton.bounds, to: bridge.webView)
                let content = controls.webView.convert(controls.webView.bounds, to: bridge.webView)
                let result = [
                    "panelX": panel.minX, "panelY": panel.minY, "panelRight": panel.maxX, "top": content.minY,
                    "x": button.minX, "y": button.minY, "width": button.width, "height": button.height,
                    "overflow": values ?? 0,
                ]
                return result
            }
            let before = try await settledGeometry()
            for button in [controls.clearButton, controls.collapseButton] {
                let image = try XCTUnwrap(button.configuration?.image)
                XCTAssertTrue(
                    image.isSymbolImage, "Conversation controls must keep native SF Symbols after message updates")
                XCTAssertEqual(button.bounds.size, CGSize(width: 44, height: 44))
                XCTAssertFalse(button.isDescendant(of: bridge.webView))
                let material = try XCTUnwrap(button.subviews.compactMap { $0 as? UIVisualEffectView }.first)
                XCTAssertNil(material.effect, "Resting controls show only their symbols")
                UIView.performWithoutAnimation { button.isHighlighted = true }
                XCTAssertTrue(material.effect is UIGlassEffect)
                if index == 0 && button === controls.clearButton {
                    let row = CGRect(
                        x: before["panelX"] ?? 0, y: before["panelY"] ?? 0,
                        width: (before["panelRight"] ?? 0) - (before["panelX"] ?? 0),
                        height: (before["top"] ?? 0) - (before["panelY"] ?? 0))
                    recordWindow(
                        "conversation-controls-pressed", window: window,
                        rect: bridge.webView.convert(row, to: window))
                }
                UIView.performWithoutAnimation { button.isHighlighted = false }
                XCTAssertNil(material.effect)
            }
            XCTAssertEqual(controls.clearButton.frame.midY, controls.collapseButton.frame.midY, accuracy: pixel)
            XCTAssertLessThanOrEqual(
                controls.collapseButton.convert(controls.collapseButton.bounds, to: bridge.webView).maxY,
                try XCTUnwrap(before["top"]) + pixel, "Conversation content must begin below the controls")
            XCTAssertGreaterThan(try XCTUnwrap(before["overflow"]), 0)
            _ = try await bridge.conversationWebView.callAsyncJavaScript(
                """
                const s=document.querySelector('.mdv-agent-scroll');s.scrollTop=s.scrollHeight;
                await new Promise(requestAnimationFrame);
                """, arguments: [:], in: nil, contentWorld: .page)
            let after = try await settledGeometry()
            // Keyboard and panel transitions may move the whole panel. The
            // controls stay anchored to its top/trailing edges while content scrolls.
            XCTAssertEqual(
                try XCTUnwrap(after["panelRight"]) - XCTUnwrap(after["x"]) - XCTUnwrap(after["width"]),
                try XCTUnwrap(before["panelRight"]) - XCTUnwrap(before["x"]) - XCTUnwrap(before["width"]),
                accuracy: pixel)
            XCTAssertEqual(
                try XCTUnwrap(after["y"]) - XCTUnwrap(after["panelY"]),
                try XCTUnwrap(before["y"]) - XCTUnwrap(before["panelY"]), accuracy: pixel)
        }
    }

    private func reader(
        _ text: String, api: ModelAPIProtocol = .chatCompletions,
        baseURL: String = "https://agent.example.test/v1", model: String = "fixture-model",
        modelKey: @escaping @MainActor () -> String = { "fixture-key" }, dataSharingAllowed: Bool = true,
        recoveryStore: ReaderRecoveryStore? = nil, webSearchClient: WebSearchClient? = nil,
        conversationStore: AgentConversationStore? = nil, pasteboard: UIPasteboard = .general
    ) async throws -> (ReaderSession, ReaderBridge, UIWindow, URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentFixtureProtocol.self]
        return try await makeReader(
            text, api: api, baseURL: baseURL, model: model,
            modelClient: ModelClient(session: URLSession(configuration: configuration)),
            modelKey: modelKey, dataSharingAllowed: dataSharingAllowed, recoveryStore: recoveryStore,
            modelCatalog: ModelCatalog(session: URLSession(configuration: configuration)),
            webSearchClient: webSearchClient, conversationStore: conversationStore, pasteboard: pasteboard)
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
            try await bridge.conversationWebView.evaluateJavaScript(
                "!document.querySelector('.mdv-agent-send').disabled") as? Bool
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
            try await bridge.conversationWebView.evaluateJavaScript(
                "!document.querySelector('.mdv-agent-send').disabled") as? Bool
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
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "const input = document.querySelector('.mdv-composer textarea'); input.value = '下一轮草稿'; input.dispatchEvent(new Event('input', {bubbles:true})); document.querySelector('[data-agent-action=retry]').click();"
        )
        try await wait { session.needsDataSharingConsent }
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 1)
        session.finishDataSharingConsent(allowed: false)
        try await wait {
            try await bridge.conversationWebView.evaluateJavaScript(
                "!document.querySelector('.mdv-agent-send').disabled") as? Bool
                == true
        }
        let cancelled = try await state(bridge)
        XCTAssertEqual(cancelled["draft"] as? String, "下一轮草稿")
        XCTAssertTrue(((cancelled["turns"] as? [[String: Any]])?.last?["text"] as? String)?.contains("部分回答") == true)
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('[data-agent-action=retry]').click();")
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
            try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelectorAll('.mdv-assistant-turn .katex').length === 1 && document.querySelectorAll('.mdv-assistant-turn .mdv-mermaid svg').length === 1"
            ) as? Bool == true
        }
        let first = try await state(bridge)
        XCTAssertEqual((first["turns"] as? [[String: Any]])?.count, 2)
        let unsafe =
            try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelectorAll('.mdv-turn script,.mdv-turn iframe,.mdv-turn [onerror]').length") as? Int
        XCTAssertEqual(unsafe, 0)
        let localLinks =
            try await bridge.conversationWebView.evaluateJavaScript(
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
        let firstID = firstContext["documentID"] as? String
        let latestID = latestContext["documentID"] as? String
        XCTAssertNil(firstContext["reference"])
        XCTAssertNil(latestContext["reference"])
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
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-composer textarea').value = '尚未发送的新草稿'; document.querySelector('.mdv-composer textarea').dispatchEvent(new Event('input',{bubbles:true}));"
        )
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: "# 后续文档\n\n不应进入重试请求。\n")
        _ = try await bridge.conversationWebView.evaluateJavaScript(
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
        XCTAssertNil(context["reference"])
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
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-send').click();")
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
        let dots = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelectorAll('.mdv-agent-dot').length")
        XCTAssertEqual(dots as? Int, 3)
        _ = try await bridge.conversationWebView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
        try await wait { bridge.session.agentTransport.activeID == nil }
        var remainingDots = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelectorAll('.mdv-agent-dot').length")
        XCTAssertEqual(remainingDots as? Int, 0)

        try await send("Second question", bridge: bridge)
        try await wait {
            try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelector('.mdv-assistant-turn[data-state=streaming] strong')?.textContent === 'partial answer' && !document.querySelector('.mdv-agent-dot')"
            ) as? Bool == true
        }
        let marker = try await bridge.conversationWebView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('.mdv-assistant-turn[data-state=streaming] .mdv-response-block > p'), '::after').content"
        )
        XCTAssertEqual(marker as? String, "\"\"")
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "const input = document.querySelector('.mdv-agent-input'); input.value = 'Next draft'; input.dispatchEvent(new Event('input', {bubbles:true})); document.querySelector('.mdv-agent-send').click()"
        )
        try await wait { bridge.session.agentTransport.activeID == nil }
        var result = try await state(bridge)
        XCTAssertEqual(result["draft"] as? String, "Next draft")
        XCTAssertTrue(
            ((result["turns"] as? [[String: Any]])?.last?["text"] as? String)?.contains("partial answer") == true)
        let stoppedMarker = try await bridge.conversationWebView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('.mdv-assistant-turn:last-child .mdv-response-block > p'), '::after').content"
        )
        XCTAssertEqual(stoppedMarker as? String, "none")

        try await send("Third question", bridge: bridge)
        try await wait {
            (try await self.state(bridge)["turns"] as? [[String: Any]])?.last?["state"] as? String == "failed"
        }
        remainingDots = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelectorAll('.mdv-agent-dot').length")
        XCTAssertEqual(remainingDots as? Int, 0)
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('[data-agent-action=retry]').click()")
        try await completed(bridge, count: 6)
        result = try await state(bridge)
        XCTAssertEqual((result["turns"] as? [[String: Any]])?.last?["text"] as? String, "A complete answer.")
        remainingDots = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelectorAll('.mdv-agent-dot').length")
        XCTAssertEqual(remainingDots as? Int, 0)
    }

    func testComposerGrowsAtTheFirstCharacterOfEachWrappedLine() async throws {
        let (_, bridge, window, _) = try await reader("# Reading\n")
        defer { window.endEditing(true) }
        _ = try await bridge.call("toggleAgent")
        try await wait {
            bridge.composer.view.window != nil
        }
        let input = try XCTUnwrap(
            bridge.composer.view)
        try await wait { input.isFirstResponder && input.bounds.width > 0 }
        let question = "帮我搜索相关资料，解释 kvcache的作用以及为什么它这么重要，多画一点图辅助我理解。"
        var capturedFirstWrap = false
        for width in [360, 362, 380, 400, 420] {
            bridge.conversationPanel.frame.size.width = CGFloat(width)
            bridge.conversationPanel.setNeedsLayout()
            bridge.conversationPanel.layoutIfNeeded()
            _ = try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelector('.mdv-agent-input').value = ''")
            try await wait { input.text.isEmpty }
            for character in question {
                input.insertText(String(character))
                let text = input.text ?? ""
                try await wait {
                    try await bridge.conversationWebView.callAsyncJavaScript(
                        "return document.querySelector('.mdv-agent-input').value === text;",
                        arguments: ["text": text], in: nil, contentWorld: .page) as? Bool == true
                }
                let minimum = 52.0
                let maximum = max(52, min(160, bridge.conversationPanel.bounds.height * 0.3))
                let natural = input.sizeThatFits(
                    CGSize(width: input.bounds.width, height: .greatestFiniteMagnitude)
                ).height
                let expected = min(maximum, max(minimum, ceil(natural)))
                if !capturedFirstWrap && expected > minimum + (input.font?.lineHeight ?? 16) / 2 {
                    capturedFirstWrap = true
                    recordWindow(
                        "composer-first-wrapped-character", window: window,
                        rect: input.convert(input.bounds, to: window).insetBy(dx: -16, dy: -16))
                }
                XCTAssertGreaterThanOrEqual(
                    input.bounds.height + 0.5, expected,
                    "The first wrapped character must fit: text=\(text), native=\(input.bounds), natural=\(natural), maximum=\(maximum)"
                )
            }
            input.selectedRange = NSRange(location: 0, length: input.text.utf16.count)
            input.deleteBackward()
            try await wait { input.bounds.height <= 52.5 }
            XCTAssertTrue(input.text.isEmpty)
        }
    }

    func testCapsuleKeepsInputAndSendHitRegionsSeparate() async throws {
        AgentFixtureProtocol.queue.reset([])
        let (_, bridge, _, _) = try await reader("# Document\n")
        _ = try await bridge.call("toggleAgent")
        // The Web layout message mounts the native input after opening the panel.
        try await wait {
            bridge.composer.view.window != nil
        }
        let input = try XCTUnwrap(
            bridge.composer.view)
        XCTAssertFalse(input.isDescendant(of: bridge.webView))
        try await wait { !input.isHidden && input.frame.width > 0 }
        let pixel = 1 / bridge.webView.traitCollection.displayScale
        for text in ["A short question", String(repeating: "A longer question on several lines. ", count: 20)] {
            _ = try await bridge.conversationWebView.callAsyncJavaScript(
                "const input = document.querySelector('.mdv-agent-input'); input.value = text; input.dispatchEvent(new Event('input', {bubbles:true}));",
                arguments: ["text": text], in: nil, contentWorld: .page)
            try await wait { input.text == text }
            bridge.conversationPanel.layoutIfNeeded()
            let field = input.convert(input.bounds, to: bridge.webView)
            let send = bridge.conversationPanel.sendButton
            let button = send.convert(send.bounds, to: bridge.webView)
            XCTAssertFalse(field.intersects(button), "The input and send control must have separate layout regions")
            for x in [button.minX + pixel / 2, button.midX, button.maxX - pixel / 2] {
                for y in [button.minY + pixel / 2, button.midY, button.maxY - pixel / 2] {
                    let hit = bridge.webView.superview?.hitTest(CGPoint(x: x, y: y), with: nil)
                    XCTAssertFalse(hit === input || hit?.isDescendant(of: input) == true)
                }
            }
            XCTAssertGreaterThanOrEqual(button.width, 44)
            XCTAssertGreaterThanOrEqual(button.height, 44)
        }
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
    }

    func testConversationPanelFollowsNativeBottomBoundaryWithoutMovingTheDocument() async throws {
        AgentFixtureProtocol.queue.reset([])
        let (_, bridge, window, _) = try await reader(
            "# Reading\n\nA selected passage to discuss.\n\n"
                + String(repeating: "More reading content.\n\n", count: 60))
        defer { window.endEditing(true) }
        for size in [CGSize(width: 390, height: 844), CGSize(width: 1024, height: 768)] {
            bridge.webView.superview?.superview?.autoresizingMask = []
            bridge.webView.superview?.superview?.frame = CGRect(origin: .zero, size: size)
            _ = try await bridge.webView.evaluateJavaScript(
                "(() => { const r = document.createRange(); r.selectNodeContents(document.querySelector('.mdv-article p')); const s = getSelection(); s.removeAllRanges(); s.addRange(r); window.MarkdownIt.askSelection(); })()"
            )
            try await wait { bridge.session.agentOpen }
            let input = try XCTUnwrap(
                bridge.composer.view)
            // Opening focuses after the panel transition. Complete that entry
            // before dismissing input to supply isolated native geometry below.
            try await wait { input.isFirstResponder }
            bridge.composer.blur()
            try await wait {
                !input.isFirstResponder
                    && window.keyboardLayoutGuide.layoutFrame.height <= window.safeAreaInsets.bottom + 1
            }
            _ = try await bridge.conversationWebView.evaluateJavaScript(
                "(() => { const f = document.querySelector('.mdv-agent-input'); f.value = 'A question about this passage.'; f.dispatchEvent(new Event('input', {bubbles:true})); })()"
            )
            func geometry() async throws -> [String: Double] {
                let panel = bridge.conversationPanel!
                let container = try XCTUnwrap(bridge.webView.superview)
                let frame = panel.convert(panel.bounds, to: container)
                let field = input.convert(input.bounds, to: container)
                let content = panel.webView.convert(panel.webView.bounds, to: container)
                let article =
                    try await bridge.webView.evaluateJavaScript(
                        "(() => {const r=document.querySelector('.mdv-article').getBoundingClientRect();return [r.y,r.width];})()"
                    ) as? [Double] ?? []
                return [
                    "panelTop": frame.minY, "panelBottom": frame.maxY, "composerBottom": field.maxY,
                    "inputTop": field.minY, "inputBottom": field.maxY, "referenceTop": content.maxY,
                    "articleTop": article.first ?? 0, "articleWidth": article.last ?? 0,
                ]
            }
            let baseline = try await geometry()
            let bottom = try XCTUnwrap(baseline["composerBottom"])
            let panelBottom = try XCTUnwrap(baseline["panelBottom"])
            for inset in [136.0, 72.0, 0.0] {
                // Supply measured native geometry at the bridge boundary, not a keyboard-height guess.
                bridge.webView.inputBottomInset = inset
                let panelTarget =
                    inset > 0 ? min(panelBottom, size.height - inset - ReaderDesign.floatingGap) : panelBottom
                let target = bottom - (panelBottom - panelTarget)
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
                for key in ["articleTop", "articleWidth"] {
                    XCTAssertEqual(try XCTUnwrap(result[key]), try XCTUnwrap(baseline[key]), accuracy: 0.5)
                }
                XCTAssertEqual(try XCTUnwrap(result["panelBottom"]), panelTarget, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(result["panelTop"]), 0)
                XCTAssertEqual(
                    try XCTUnwrap(result["panelBottom"]) - XCTUnwrap(result["composerBottom"]),
                    panelBottom - bottom, accuracy: 0.5, "The input keeps its spacing inside the panel")
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
                (try await geometry()["composerBottom"] ?? bottom) < bottom - 2
            }
            bridge.webView.inputBottomInset = 72
            bridge.webView.inputBottomInset = 0
            try await wait { abs((try await geometry()["composerBottom"] ?? 0) - bottom) <= 0.5 }
            _ = try await bridge.call("closeAgent")
        }
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
    }

    func testConversationComposerFitsAShortReadingViewport() async throws {
        let (_, bridge, window, _) = try await reader("# Reading\n\nA passage to discuss.\n")
        defer { window.endEditing(true) }
        try await sourceMode(bridge)
        bridge.webView.superview?.superview?.autoresizingMask = []
        bridge.webView.superview?.superview?.frame = CGRect(x: 0, y: 0, width: 750, height: 178)
        _ = try await bridge.call("toggleAgent")
        try await wait {
            let open = try await self.state(bridge)["open"] as? Bool == true
            let settled =
                try await bridge.webView.evaluateJavaScript(
                    "document.querySelector('.mdv-app').getAnimations({subtree:true}).every(a=>a.playState==='finished')"
                ) as? Bool == true
            return open && settled
        }
        for reference in [true, false] {
            if !reference {
                _ = try await bridge.conversationWebView.evaluateJavaScript(
                    "document.querySelector('.mdv-reference-remove')?.click()")
            }
            let panel = bridge.conversationPanel!
            panel.layoutIfNeeded()
            let send = panel.sendButton.convert(panel.sendButton.bounds, to: panel)
            let input = panel.composer.view.convert(panel.composer.view.bounds, to: panel)
            XCTAssertLessThanOrEqual(send.maxY, panel.bounds.height, "reference=\(reference)")
            XCTAssertLessThanOrEqual(input.maxY, panel.bounds.height)
            XCTAssertLessThanOrEqual(
                panel.clearButton.frame.maxY, panel.webView.frame.minY,
                "Conversation scrolling begins below the native header")
        }
    }

    func testConversationInputClearsDockedKeyboardWithoutDoubleCountingItsHeight() async throws {
        let (_, bridge, window, _) = try await reader("# Reading\n\nA passage to discuss.\n")
        defer { window.endEditing(true) }
        let controller = try XCTUnwrap(window.rootViewController)
        bridge.webView.superview?.superview?.removeFromSuperview()
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
        let input = bridge.composer.view
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
            let container = try XCTUnwrap(bridge.webView.superview?.superview)
            container.autoresizingMask = []
            container.frame = CGRect(x: 0, y: 0, width: width, height: height)
            container.layoutIfNeeded()
            try await wait {
                let data =
                    try await bridge.webView.evaluateJavaScript(
                        "(() => {const app=document.querySelector('.mdv-app');return [app.dataset.outlineLayout,app.dataset.agentLayout];})()"
                    ) as? [String]
                let reserved = session.agentOpen && width >= 756 ? bridge.conversationPanel.bounds.width + 16 : 0
                return data == [width < 668 ? "overlay" : "side", width < 756 ? "sheet" : "side"]
                    && abs(bridge.webView.bounds.width - (width - reserved)) < 1
            }
            // ResizeObserver reconciles the panel policy after viewport geometry changes.
            // Its resulting transition must finish before comparing native and Web geometry.
            try await settled()
        }
        func panels(outline: Bool, agent: Bool, sheet: Bool, file: StaticString = #filePath, line: UInt = #line)
            async throws
        {
            try await wait(file: file, line: line) {
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
        func assertReadingGutters() async throws {
            let value =
                try await bridge.webView.evaluateJavaScript(
                    "(() => {const s=getComputedStyle(document.querySelector('.mdv-article'));return [parseFloat(s.paddingLeft),parseFloat(s.paddingRight)];})()"
                ) as? [Double]
            let gutters = try XCTUnwrap(value)
            XCTAssertEqual(gutters[0], 36, accuracy: 0.5)
            XCTAssertEqual(gutters[1], gutters[0], accuracy: 0.5)
        }
        try await resize(1376)
        if !session.outlineExpanded { _ = try await bridge.call("toggleOutline") }
        try await openAI()
        try await send("Keep this conversation", bridge: bridge)
        try await completed(bridge)
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "const input=document.querySelector('.mdv-agent-input'); input.value='Draft kept across layouts'; input.dispatchEvent(new Event('input',{bubbles:true}));"
        )
        try await panels(outline: true, agent: true, sheet: false)
        try await assertReadingGutters()
        _ = try await bridge.conversationWebView.evaluateJavaScript(
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
            try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelector('.mdv-agent-scroll').scrollTop") as? Double
        XCTAssertEqual(
            try XCTUnwrap(conversationPosition), 80, accuracy: 1,
            "Switching auxiliary panels must preserve manual conversation browsing")
        let widths = [
            bridge.webView.bounds.width, bridge.webView.frame.maxX, bridge.conversationPanel.frame.minX,
            bridge.conversationPanel.bounds.width,
        ]
        XCTAssertGreaterThanOrEqual(widths[0], 420)
        XCTAssertEqual(widths[2], widths[1], accuracy: 0.5)
        XCTAssertEqual(widths[3], 320, accuracy: 1)
        try await assertReadingGutters()
        XCTAssertEqual(834 - bridge.webView.bounds.width, 336, accuracy: 0.5)
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
        XCTAssertEqual(bridge.webView.bounds.width, 500, accuracy: 0.5)
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
            try await bridge.conversationWebView.evaluateJavaScript(
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

    func testPreviewSelectionsKeepSemanticsBeforeAfterSendingAndRestoring() async throws {
        let markdown = #"""
            # Selected heading

            Plain **bold words** and *italic words*, ``inline `code` ``, [linked words](https://example.com).

            Super <sup>super words</sup> and sub <sub>sub words</sub>.

            | Name | Value |
            | --- | --- |
            | **table bold** | unselected cell |

            > Quoted words.

            3. Ordered words.
            """#
        let cases = [
            ("strong", "strong", "bold words"), ("em", "em", "italic words"),
            ("p code", "code", "inline `code`"), ("p a", "a", "linked words"),
            ("sup", "sup", "super words"), ("sub", "sub", "sub words"),
            ("td strong", "strong", "table bold"), ("blockquote p", "blockquote", "Quoted words."),
            ("h1", "h1", "Selected heading"), ("li", "ol[start='3']", "Ordered words."),
        ]
        AgentFixtureProtocol.queue.reset(cases.map { _ in AgentFixture(text: "A response.") })
        let (session, bridge, _, _) = try await reader(markdown)
        func assertSemantic(_ surface: String, tag: String, text: String) async throws {
            let value =
                try await bridge.conversationWebView.callAsyncJavaScript(
                    """
                    const surface=document.querySelector(selector);
                    return {text:surface?.textContent.trim(),semantic:surface?.querySelector(tag)?.textContent.trim(),
                      href:surface?.querySelector('a')?.getAttribute('href')};
                    """, arguments: ["selector": surface, "tag": tag], in: nil, contentWorld: .page)
                as? [String: String]
            XCTAssertEqual(value?["text"], text, surface)
            XCTAssertEqual(value?["semantic"], text, "\(surface) must retain \(tag)")
            if tag == "a" { XCTAssertEqual(value?["href"], "https://example.com") }
        }
        for (index, item) in cases.enumerated() {
            await session.closeAgent()
            _ = try await bridge.webView.callAsyncJavaScript(
                """
                const range=document.createRange();range.selectNodeContents(document.querySelector('.mdv-article '+selector));
                getSelection().removeAllRanges();getSelection().addRange(range);
                """, arguments: ["selector": item.0], in: nil, contentWorld: .page)
            _ = try await bridge.call("askSelection")
            try await wait { session.agentOpen }
            try await assertSemantic(".mdv-composer-reference .mdv-rich-text", tag: item.1, text: item.2)
            if item.0 == "td strong" {
                let tables =
                    try await bridge.conversationWebView.evaluateJavaScript(
                        "document.querySelectorAll('.mdv-composer-reference table').length") as? Int
                XCTAssertEqual(
                    tables, 0, "A selection confined to one cell retains inline content without inventing a grid")
            }
            try await send("Explain selection \(index)", bridge: bridge)
            try await completed(bridge, count: (index + 1) * 2)
            let reference = ".mdv-user-turn:nth-of-type(\(index * 2 + 1)) .mdv-message-reference"
            try await assertSemantic(reference + " summary .mdv-rich-text", tag: item.1, text: item.2)
            _ = try await bridge.conversationWebView.callAsyncJavaScript(
                "document.querySelector(selector+' summary').click()", arguments: ["selector": reference],
                in: nil, contentWorld: .page)
            try await assertSemantic(reference + " > .mdv-rich-text", tag: item.1, text: item.2)
        }
        let captured = try await bridge.call("captureRecovery")
        let saved = try XCTUnwrap(captured as? [String: Any])
        _ = try await bridge.call(
            "openDocument",
            arguments: [
                "payload": [
                    "token": session.documentToken, "name": "selections.md", "text": markdown, "recovery": saved,
                ]
            ])
        for (index, item) in cases.enumerated() {
            let reference = ".mdv-user-turn:nth-of-type(\(index * 2 + 1)) .mdv-message-reference"
            try await assertSemantic(reference + " summary .mdv-rich-text", tag: item.1, text: item.2)
            try await assertSemantic(reference + " > .mdv-rich-text", tag: item.1, text: item.2)
        }
        XCTAssertEqual(session.document?.text, markdown)
    }

    func testGeneratedContentReferencesUseSourcesAcrossTheEntireLifecycle() async throws {
        let formula = #"\operatorname{Attention}(Q,K,V)=\operatorname{softmax}\left(\frac{QK^\top}{\sqrt{d_k}}\right)V"#
        let markdown = """
            # Semantic units

            $$
            \(formula)
            $$

            Inline $x^2$.

            | Formula | Value |
            | --- | --- |
            | $y_1$ | other |

            ```mermaid
            flowchart LR
              Alpha --> Beta
            ```
            """
        let cases = [
            (".mdv-math[data-math-display=true] .katex-html", ".katex", formula),
            ("p .mdv-math .katex-html", ".katex", "x^2"),
            ("table", ".katex", "y_1"),
            (".mdv-mermaid svg", ".mdv-mermaid svg", "Alpha --> Beta"),
        ]
        AgentFixtureProtocol.queue.reset(cases.map { _ in AgentFixture(text: "A response.") })
        let (session, bridge, _, _) = try await reader(markdown)
        try await wait {
            try await bridge.webView.evaluateJavaScript("!!document.querySelector('.mdv-article .mdv-mermaid svg')")
                as? Bool == true
        }
        for (index, item) in cases.enumerated() {
            await session.closeAgent()
            _ = try await bridge.webView.callAsyncJavaScript(
                """
                const range=document.createRange();range.selectNodeContents(document.querySelector('.mdv-article '+selector));
                getSelection().removeAllRanges();getSelection().addRange(range);
                """, arguments: ["selector": item.0], in: nil, contentWorld: .page)
            _ = try await bridge.call("askSelection")
            try await wait { session.agentOpen }
            let capturedValue = try await bridge.call("captureRecovery")
            let captured = try XCTUnwrap(capturedValue as? [String: Any])
            let conversation = try XCTUnwrap(captured["conversation"] as? [String: Any])
            let attachment = try XCTUnwrap(conversation["attachment"] as? [String: Any])
            let quote = try XCTUnwrap(attachment["markdown"] as? String)
            XCTAssertTrue(quote.contains(item.2), quote)
            XCTAssertFalse(quote.contains("katex-html"))
            XCTAssertFalse(quote.contains("<svg"))
            func expectRendered(_ selector: String) async throws {
                try await wait {
                    try await bridge.conversationWebView.callAsyncJavaScript(
                        "return !!document.querySelector(selector)?.querySelector(content)",
                        arguments: ["selector": selector, "content": item.1], in: nil, contentWorld: .page) as? Bool
                        == true
                }
            }
            try await expectRendered(".mdv-composer-reference")
            if index == 0 {
                let image = try await bridge.webView.takeSnapshot(configuration: nil)
                let attachment = XCTAttachment(image: image)
                attachment.name = "formula-reference-before-sending"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            try await send("Explain unit \(index)", bridge: bridge)
            try await completed(bridge, count: (index + 1) * 2)
            let reference = ".mdv-user-turn:nth-of-type(\(index * 2 + 1)) .mdv-message-reference"
            try await expectRendered(reference + " summary")
            if index == 0 {
                let image = try await bridge.webView.takeSnapshot(configuration: nil)
                let attachment = XCTAttachment(image: image)
                attachment.name = "formula-reference-after-sending"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            _ = try await bridge.conversationWebView.callAsyncJavaScript(
                "document.querySelector(selector+' summary').click()", arguments: ["selector": reference],
                in: nil, contentWorld: .page)
            try await expectRendered(reference + " > .mdv-rich-text")
        }
        let savedValue = try await bridge.call("captureRecovery")
        let saved = try XCTUnwrap(savedValue as? [String: Any])
        _ = try await bridge.call(
            "openDocument",
            arguments: [
                "payload": [
                    "token": session.documentToken, "name": "units.md", "text": markdown, "recovery": saved,
                ]
            ])
        try await wait {
            try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelectorAll('.mdv-message-reference summary .katex').length===3 && document.querySelectorAll('.mdv-message-reference summary .mdv-mermaid svg').length===1"
            ) as? Bool == true
        }
        XCTAssertEqual(session.document?.text, markdown)
    }

    func testFollowingDoesNotOverwriteElasticOverscrollForTouchOrWheel() async throws {
        let bridge = try await scrollingConversation()
        let result =
            try await bridge.conversationWebView.callAsyncJavaScript(
                """
                const s=document.querySelector('.mdv-agent-scroll'), frame=()=>new Promise(requestAnimationFrame);
                s.style.maxHeight='140px';await frame();await frame();
                const property=Object.getOwnPropertyDescriptor(Element.prototype,'scrollTop');
                const bottom=s.scrollHeight-s.clientHeight;
                let writes=0;
                Object.defineProperty(s,'scrollTop',{configurable:true,
                  get(){return bottom+32},set(value){writes++;property.set.call(this,value)}});
                try {
                  s.dispatchEvent(new WheelEvent('wheel',{deltaY:100}));
                  s.dispatchEvent(new Event('scroll'));
                  const touch=(type,y)=>{const event=new Event(type);
                    Object.defineProperty(event,'touches',{value:y===null?[]:[{clientY:y}]});s.dispatchEvent(event)};
                  touch('touchstart',200);touch('touchmove',100);touch('touchend',null);
                  s.dispatchEvent(new Event('scroll'));await frame();await frame();
                  return {writes,overscroll:s.scrollTop-bottom};
                } finally {delete s.scrollTop;}
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Double]
        XCTAssertEqual(result?["writes"], 0, "Following must leave system boundary rebound uninterrupted")
        XCTAssertEqual(result?["overscroll"], 32)
        _ = try await bridge.conversationWebView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
    }

    func testConversationFadesOnlyTheEdgesWithOffscreenContent() async throws {
        let bridge = try await scrollingConversation()
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').style.maxHeight = '140px';")
        try await wait {
            try await bridge.conversationWebView.evaluateJavaScript(
                "(() => { const s = document.querySelector('.mdv-agent-scroll'); return s.clientHeight === 140 && s.scrollHeight > s.clientHeight; })()"
            ) as? Bool == true
        }
        func expectEdges(top: Bool, bottom: Bool) async throws {
            try await wait {
                try await bridge.conversationWebView.callAsyncJavaScript(
                    "const s = document.querySelector('.mdv-agent-scroll'); return s.hasAttribute('data-scrolled') === top && s.hasAttribute('data-more-below') === bottom;",
                    arguments: ["top": top, "bottom": bottom], in: nil, contentWorld: .page) as? Bool == true
            }
            let style =
                try await bridge.conversationWebView.evaluateJavaScript(
                    "(() => { const s = getComputedStyle(document.querySelector('.mdv-agent-scroll')); return { top: s.getPropertyValue('--mdv-scroll-top-alpha').trim(), bottom: s.getPropertyValue('--mdv-scroll-bottom-alpha').trim(), mask: s.maskImage }; })()"
                ) as? [String: String]
            XCTAssertEqual(style?["top"], top ? "transparent" : "#000")
            XCTAssertEqual(style?["bottom"], bottom ? "transparent" : "#000")
            XCTAssertTrue(style?["mask"]?.contains("linear-gradient") == true)
        }
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "const s = document.querySelector('.mdv-agent-scroll'); s.dispatchEvent(new WheelEvent('wheel',{deltaY:-100})); s.scrollTop = 0;"
        )
        try await expectEdges(top: false, bottom: true)
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').scrollTop = 100;")
        try await expectEdges(top: true, bottom: true)
        let screenshot: UIImage = try await withCheckedThrowingContinuation { continuation in
            bridge.webView.takeSnapshot(with: nil) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? ModelError.invalidResponse)
                }
            }
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Conversation top and bottom scroll fades"
        attachment.lifetime = .keepAlways
        add(attachment)
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').scrollTop = 100000;")
        try await expectEdges(top: true, bottom: false)
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-send').click(); document.querySelector('.mdv-conversation').textContent = 'Short reply.';"
        )
        try await expectEdges(top: false, bottom: false)
    }

    func testReplyFollowsViewportChangesAndYieldsToManualBrowsing() async throws {
        let bridge = try await scrollingConversation()
        let atBottom =
            "(() => { const s = document.querySelector('.mdv-agent-scroll'); return Math.abs(s.scrollHeight - s.clientHeight - s.scrollTop) < 1; })()"
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').style.maxHeight = '96px'")
        try await wait(timeout: 3) {
            try await bridge.conversationWebView.evaluateJavaScript(atBottom) as? Bool == true
        }

        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "(() => { const s = document.querySelector('.mdv-agent-scroll'); s.dispatchEvent(new WheelEvent('wheel', {deltaY:-100})); s.scrollTop = 0; s.style.maxHeight = '140px'; })()"
        )
        try await wait {
            try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelector('.mdv-agent-scroll').clientHeight === 140") as? Bool == true
        }
        let manualPosition = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').scrollTop")
        XCTAssertEqual(manualPosition as? Double, 0)
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "(() => { const s = document.querySelector('.mdv-agent-scroll'); s.scrollTop = s.scrollHeight; s.dispatchEvent(new WheelEvent('wheel', {deltaY:100})); })()"
        )
        _ = try await bridge.conversationWebView.callAsyncJavaScript(
            "await new Promise(requestAnimationFrame); document.querySelector('.mdv-agent-scroll').style.maxHeight = '80px';",
            arguments: [:], in: nil, contentWorld: .page)
        try await wait(timeout: 3) {
            try await bridge.conversationWebView.evaluateJavaScript(atBottom) as? Bool == true
        }
        _ = try await bridge.conversationWebView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
    }

    func testConversationFollowingCorrectsALateScrollAfterViewportResize() async throws {
        let bridge = try await scrollingConversation()
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').style.maxHeight = '140px'")
        try await wait {
            try await bridge.conversationWebView.evaluateJavaScript(
                "(() => { const s = document.querySelector('.mdv-agent-scroll'); return s.clientHeight === 140 && Math.abs(s.scrollHeight - s.clientHeight - s.scrollTop) < 1; })()"
            ) as? Bool == true
        }
        let result =
            try await bridge.conversationWebView.callAsyncJavaScript(
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
        _ = try await bridge.conversationWebView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
    }

    func testManualConversationScrollDoesNotSnapBeforeReachingTheEnd() async throws {
        let bridge = try await scrollingConversation()
        let positions =
            try await bridge.conversationWebView.callAsyncJavaScript(
                """
                const scroll = document.querySelector('.mdv-agent-scroll');
                const frame = () => new Promise(requestAnimationFrame);
                scroll.style.maxHeight = '140px';
                await frame();
                await frame();
                scroll.dispatchEvent(new WheelEvent('wheel', { deltaY: -100 }));
                scroll.scrollTop = scroll.scrollHeight - scroll.clientHeight - 40;
                await frame();
                await frame();
                const before = scroll.scrollTop;
                const remaining = scroll.scrollHeight - scroll.clientHeight - before;
                // A small downward gesture must leave the scroll physics to WebKit,
                // rather than replacing it with an application-generated jump.
                scroll.dispatchEvent(new WheelEvent('wheel', { deltaY: 1 }));
                await frame();
                await frame();
                return { before, remaining, after: scroll.scrollTop };
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Double]
        let value = try XCTUnwrap(positions)
        XCTAssertEqual(try XCTUnwrap(value["remaining"]), 40, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(value["after"]), try XCTUnwrap(value["before"]), accuracy: 0.5)
        _ = try await bridge.conversationWebView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
    }

    func testConversationFollowingSurvivesReturningToBottomAndResizingInTheSameFrame() async throws {
        let bridge = try await scrollingConversation()
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').style.maxHeight = '140px'")
        try await wait {
            try await bridge.conversationWebView.evaluateJavaScript(
                "(() => { const s = document.querySelector('.mdv-agent-scroll'); return s.clientHeight === 140 && Math.abs(s.scrollHeight - s.clientHeight - s.scrollTop) < 1; })()"
            ) as? Bool == true
        }
        let result =
            try await bridge.conversationWebView.callAsyncJavaScript(
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
        _ = try await bridge.conversationWebView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
    }

    func testPendingConversationFollowYieldsToNewerUpwardNavigation() async throws {
        let bridge = try await scrollingConversation()
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').style.maxHeight = '140px'")
        try await wait {
            try await bridge.conversationWebView.evaluateJavaScript(
                "(() => { const s = document.querySelector('.mdv-agent-scroll'); return s.clientHeight === 140 && Math.abs(s.scrollHeight - s.clientHeight - s.scrollTop) < 1; })()"
            ) as? Bool == true
        }
        let result =
            try await bridge.conversationWebView.callAsyncJavaScript(
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
        _ = try await bridge.conversationWebView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
    }

    func testTouchFollowingResumesWhenMomentumReachesTheEndAfterRelease() async throws {
        let bridge = try await scrollingConversation()
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-scroll').style.maxHeight = '140px'")
        try await wait {
            try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelector('.mdv-agent-scroll').clientHeight === 140") as? Bool == true
        }
        let result =
            try await bridge.conversationWebView.callAsyncJavaScript(
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
        _ = try await bridge.conversationWebView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click()")
    }

    private func selectSource(_ text: String, bridge: ReaderBridge) throws {
        let range = (bridge.sourceEditor.history.text as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { throw CocoaError(.coderReadCorrupt) }
        bridge.sourceEditor.textView.selectedRange = range
    }

    func testPreviewQuotePreservesInlineFormattingAtDelimiterBoundaries() async throws {
        let markdown = #"""
            <strong> 随堂练</strong>：某客户持有合格股数 1,500 股。

            <strong>标签：</strong>紧接正文，<em> 倾斜 </em>与<del> 删除 </del>。

            普通 **加粗**，字面标记 \*\*保留\*\*，代码 `**不加粗**`。
            """#
        AgentFixtureProtocol.queue.reset([AgentFixture(text: "引用已读取。")])
        let (_, bridge, _, _) = try await reader(markdown)
        let original =
            try await bridge.webView.evaluateJavaScript(
                "document.querySelector('.mdv-article').textContent") as? String
        _ = try await bridge.webView.evaluateJavaScript(
            """
            (() => {
              const range = document.createRange();
              range.selectNodeContents(document.querySelector('.mdv-article'));
              getSelection().removeAllRanges();
              getSelection().addRange(range);
            })()
            """)
        _ = try await bridge.call("askSelection")
        try await wait { bridge.session.agentOpen }

        func assertFormatting(_ selector: String) async throws {
            let result =
                try await bridge.conversationWebView.callAsyncJavaScript(
                    """
                    const content = document.querySelector(selector);
                    const texts = tag => [...content.querySelectorAll(tag)].map(node => node.textContent);
                    return { text: content.textContent, strong: texts('strong'), em: texts('em'),
                      del: texts('del'), code: texts('code') };
                    """, arguments: ["selector": selector], in: nil, contentWorld: .page) as? [String: Any]
            let value = try XCTUnwrap(result)
            XCTAssertEqual(value["strong"] as? [String], [" 随堂练", "标签：", "加粗"])
            XCTAssertEqual(value["em"] as? [String], [" 倾斜 "])
            XCTAssertEqual(value["del"] as? [String], [" 删除 "])
            XCTAssertEqual(value["code"] as? [String], ["**不加粗**"])
            XCTAssertEqual(
                (value["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                original?.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        try await assertFormatting(".mdv-composer-reference .mdv-rich-text")
        let image = try await bridge.webView.takeSnapshot(configuration: nil)
        let screenshot = XCTAttachment(image: image)
        screenshot.name = "preview-quote-inline-formatting"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        try await send("解释引用。", bridge: bridge)
        try await completed(bridge)
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-message-reference summary').click()")
        try await assertFormatting(".mdv-message-reference .mdv-rich-text")
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
            bridge.webView.superview?.superview?.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            try await wait {
                try await bridge.webView.evaluateJavaScript("window.innerWidth") as? Double == width
            }
            _ = try await bridge.webView.evaluateJavaScript(
                "(() => { const range=document.createRange(); range.selectNodeContents(document.querySelector('.mdv-article')); getSelection().removeAllRanges(); getSelection().addRange(range); })()"
            )
            _ = try await bridge.call("askSelection")
            try await wait {
                guard bridge.conversationPanel.layer.animationKeys()?.isEmpty != false,
                    bridge.conversationWebView.layer.animationKeys()?.isEmpty != false
                else { return false }
                return try await bridge.conversationWebView.evaluateJavaScript(
                    """
                    (() => {
                      const panel = document.querySelector('.mdv-agent');
                      const reference = panel.querySelector('.mdv-composer-reference');
                      const animations = panel.getAnimations().concat(reference.getAnimations({ subtree: true }));
                      return !panel.hidden && animations.every(a => a.playState === 'finished');
                    })()
                    """
                ) as? Bool == true
            }
            let measured =
                try await bridge.conversationWebView.evaluateJavaScript(
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
                      const animations = row.closest('.mdv-composer-reference').getAnimations({ subtree: true });
                      const start = target.top;
                      body.scrollTop = body.scrollHeight;
                      return {
                        outside: lines.every(line => line.right <= target.left),
                        moving: animations.some(a => a.playState !== 'finished'),
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
            XCTAssertEqual(geometry["moving"] as? Bool, false, "Quote geometry must be measured after its entry motion")
            XCTAssertEqual(geometry["outside"] as? Bool, true, "Every wrapped line must avoid the removal target")
            XCTAssertGreaterThan(try XCTUnwrap(geometry["lines"] as? Int), 3)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(geometry["width"] as? Double), 44)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(geometry["height"] as? Double), 44)
            XCTAssertEqual(try XCTUnwrap(geometry["alignment"] as? Double), 0, accuracy: 0.5)
            XCTAssertGreaterThan(try XCTUnwrap(geometry["scrolled"] as? Double), 0)
            XCTAssertEqual(try XCTUnwrap(geometry["removalMovement"] as? Double), 0, accuracy: 0.5)
            // WebKit stores FloatRect components, but DOMRect adds x and width as doubles.
            // Compare computed and stored edges at the same underlying precision.
            XCTAssertLessThanOrEqual(
                Float32(try XCTUnwrap(geometry["contentBoundary"] as? Double)),
                Float32(try XCTUnwrap(geometry["targetBoundary"] as? Double)))
            XCTAssertTrue((geometry["text"] as? String)?.contains(paragraph) == true)
            XCTAssertTrue((geometry["text"] as? String)?.contains("最后一个段落。") == true)
            XCTAssertEqual(geometry["tables"] as? Int, 1)
            XCTAssertEqual(geometry["code"] as? Int, 1)
            _ = try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelector('.mdv-reference-body').scrollTop=0;")
            let snapshot = try await bridge.webView.takeSnapshot(configuration: nil)
            let attachment = XCTAttachment(image: snapshot)
            attachment.name = "selection-quote-alignment-\(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            _ = try await bridge.conversationWebView.evaluateJavaScript(
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
            let tools = try XCTUnwrap(continuation["tools"] as? [[String: Any]])
            let names = tools.compactMap {
                (api == .responses ? $0 : $0["function"] as? [String: Any] ?? [:])["name"] as? String
            }
            XCTAssertEqual(Set(names), ["get_current_time", "read_document", "edit_document"])
            XCTAssertFalse(wire.contains("fixture-key"))
            // Deliver the native save acknowledgement only after a later history action.
            _ = try await bridge.conversationWebView.evaluateJavaScript(
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
            _ = try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelector('[data-agent-action=undo]').click();")
            try await wait { session.document?.text == original }
            await session.flushChanges()
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
            try await wait {
                try await bridge.conversationWebView.evaluateJavaScript(
                    "typeof window.delayedUndoResult === 'function'")
                    as? Bool == true
            }
            let redone = bridge.moveSourceHistory(forward: true)
            XCTAssertEqual(redone, true)
            try await wait { session.document?.text == applied }
            _ = try await bridge.conversationWebView.evaluateJavaScript("window.delayedUndoResult();")
            let undoVisible =
                try await bridge.conversationWebView.evaluateJavaScript(
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
        _ = try await bridge.webView.callAsyncJavaScript(
            """
            (() => {
              const deliver = window.MarkdownIt.sourceState.bind(window.MarkdownIt);
              window.MarkdownIt.sourceState = payload => {
                if (!payload.text === expected) return deliver(payload);
                return new Promise(resolve => {
                  window.releaseUndoProjection = () => {
                    delete window.releaseUndoProjection;
                    window.MarkdownIt.sourceState = deliver;
                    resolve(deliver(payload));
                  };
                });
              };
            })();
            """, arguments: ["expected": original], in: nil, contentWorld: .page)
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
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('[data-agent-action=retry]').click();")
        try await completed(bridge)
        let requests = AgentFixtureProtocol.queue.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1], requests[2])
        let cards =
            try await bridge.conversationWebView.evaluateJavaScript(
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
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-agent-send').click();")
        try await wait { session.agentTransport.activeID == nil }
        try await wait {
            try await bridge.conversationWebView.evaluateJavaScript(
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

    func testRestoredInvalidReadReturnsToolErrorAndContinuesWithoutRepeatingCompletedCalls() async throws {
        let text = String(repeating: "中文😀\n", count: 7000)
        let doc = AgentAttachment(
            text: text, markdown: text, mode: "preview", scope: "document", location: nil, start: nil, end: nil)
        let snapshot = AgentSnapshot(
            question: "Explain this document", attachment: nil,
            history: [.init(role: "user", markdown: "Explain this document", attachment: nil, document: doc)],
            document: doc)
        let documentID = AgentContextSources.id(text)
        for api in ModelAPIProtocol.allCases {
            func call(_ id: String, offset: Int?, query: String? = nil) throws -> ModelToolCall {
                let data = try JSONSerialization.data(withJSONObject: [
                    "documentID": documentID, "characterOffset": offset as Any? ?? NSNull(),
                    "query": query as Any? ?? NSNull(),
                ])
                return .init(id: id, name: "read_document", arguments: String(decoding: data, as: UTF8.self))
            }
            let valid = try call("read-first", offset: 0)
            // Resume the exact old API shape from a previously failed saved call.
            // It must be rejected, never reinterpreted as a character position.
            let invalid = ModelToolCall(
                id: "read-byte-position", name: "read_document",
                arguments: "{\"documentID\":\"" + documentID + "\",\"offset\":33500,\"query\":null}")
            let repaired = try call("read-by-query", offset: nil, query: "中文")
            AgentFixtureProtocol.queue.reset([
                AgentFixture(calls: [valid]), AgentFixture(calls: [invalid]),
                AgentFixture(calls: [repaired]), AgentFixture(text: "Recovered answer."),
            ])
            let session = URLSessionConfiguration.ephemeral
            session.protocolClasses = [AgentFixtureProtocol.self]
            let client = ModelClient(session: URLSession(configuration: session))
            let transport = AgentModelTransport(client: client)
            let configuration = ModelConfiguration(
                baseURL: "https://agent.example.test/v1", model: "fixture", apiProtocol: api)
            var recovery: AgentModelTransport.Recovery?
            transport.checkpoint = { [weak transport] in
                guard let transport else { return }
                if let state = transport.recovery(), state.pendingTurn?.calls.first?.id == invalid.id {
                    recovery = state
                    transport.cancel()
                }
            }
            transport.start(
                id: "before-termination", token: "document", snapshot: snapshot, intent: "question",
                configuration: configuration, key: "fixture-key", capabilities: { .init(contextWindow: 32_768) },
                emit: { event in
                    if event.type == "failure" { XCTFail("Unexpected failure before checkpoint") }
                })
            try await wait { recovery != nil }
            XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 2)
            let saved = try XCTUnwrap(recovery)
            XCTAssertEqual(saved.exchanges.count, 1)
            XCTAssertTrue(saved.pendingOutputs.isEmpty)
            let restored = AgentModelTransport(client: client)
            var old = try ModelWireFormat.object(JSONEncoder().encode(saved))
            // Disposable messages from an older installed version must not
            // replace the current tool contract when restoring its journal.
            old["messages"] = [["role": "system", "content": "LEGACY_BYTE_READING_INSTRUCTIONS"]]
            try restored.restore(
                JSONDecoder().decode(
                    AgentModelTransport.Recovery.self, from: JSONSerialization.data(withJSONObject: old)))
            var finished = false
            restored.start(
                id: "manual-retry", token: "document", snapshot: snapshot, intent: "question",
                configuration: configuration, key: "fixture-key", capabilities: { .init(contextWindow: 32_768) },
                emit: { event in
                    if event.type == "failure" { XCTFail("Invalid tool arguments must not fail the answer") }
                    if event.type == "complete" { finished = true }
                })
            try await wait { finished }
            let requests = AgentFixtureProtocol.queue.requests()
            XCTAssertEqual(requests.count, 4, "Resume must not repeat the already completed reading requests")
            let continuation = String(decoding: requests[2], as: UTF8.self)
            XCTAssertTrue(continuation.contains("invalid_arguments"))
            XCTAssertTrue(continuation.contains(invalid.id))
            XCTAssertTrue(continuation.contains("nextCharacterOffset"))
            XCTAssertFalse(continuation.contains("LEGACY_BYTE_READING_INSTRUCTIONS"))
            let completed = try XCTUnwrap(restored.recovery())
            XCTAssertNil(completed.pendingTurn)
            XCTAssertEqual(completed.exchanges.count, 3)
            XCTAssertFalse(completed.toolsPaused)
            let result = try XCTUnwrap(completed.exchanges.last?.outputs.first)
            let output = try ModelWireFormat.object(Data(result.content.utf8))
            XCTAssertTrue((output["content"] as? String)?.hasPrefix("中文") == true)
            XCTAssertEqual(snapshot.document?.text, text)
        }
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
            executeTool: { call, _, _ in
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
                executeTool: { _, _, _ in
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
            let tools = try XCTUnwrap(first["tools"] as? [[String: Any]])
            let names = tools.compactMap {
                (api == .responses ? $0 : $0["function"] as? [String: Any] ?? [:])["name"] as? String
            }
            XCTAssertEqual(names, ["get_current_time"], "Selected pixels must not require an image read tool")
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
            _ = try await bridge.conversationWebView.evaluateJavaScript(
                "document.querySelector('.mdv-message-reference summary').click()")
            let frozenQuote =
                try await bridge.conversationWebView.evaluateJavaScript(
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
            XCTAssertEqual(names, ["get_current_time", "read_image"], "Preview must never offer document edit tools")
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
                .first { $0.delegate is ReaderActionMenu })
        let actionMenu = try XCTUnwrap(interaction.delegate as? ReaderActionMenu)
        let menuView = try XCTUnwrap(interaction.view)
        XCTAssertTrue(menuView.superview === bridge.webView)
        XCTAssertFalse(menuView.isUserInteractionEnabled, "The AI menu host must leave image gestures to WebKit")
        XCTAssertFalse(bridge.webView.interactions.contains { $0 === interaction })
        func action(_ id: String) throws -> UIAction {
            let config = UIEditMenuConfiguration(identifier: id as NSString, sourcePoint: CGPoint(x: 50, y: 100))
            host.show(id: id, token: session.documentToken, reference: reference, point: config.sourcePoint)
            return try XCTUnwrap(
                actionMenu.editMenuInteraction(interaction, menuFor: config, suggestedActions: [])?.children.first
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
        XCTAssertTrue(menuView.superview === bridge.webView)
        bridge.detach()
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
