import XCTest

@testable import MarkdownIt

private actor SummaryRecorder {
    private(set) var inputs: [[ChatMessage]] = []
    func summarize(_ messages: [ChatMessage]) -> String {
        inputs.append(messages)
        return
            "User prefers concise Italian answers. The earlier explanation is incomplete; no file edits were authorized."
    }
    var count: Int { inputs.count }
}

@MainActor
final class ContextMemoryTests: XCTestCase {
    private func document(_ text: String) -> AgentAttachment {
        .init(text: text, markdown: text, mode: "preview", scope: "document", location: nil, start: nil, end: nil)
    }

    private func snapshot(_ text: String = "# Document\n\nCurrent content.") -> AgentSnapshot {
        let doc = document(text)
        return AgentSnapshot(
            question: "Continue in Italian", attachment: nil,
            history: [
                .init(role: "user", markdown: "Please explain concisely in Italian", attachment: nil, document: doc),
                .init(
                    role: "assistant", markdown: String(repeating: "Earlier explanation. ", count: 4500),
                    attachment: nil, status: "stopped"),
                .init(role: "user", markdown: "Continue in Italian", attachment: nil, document: doc),
            ], document: doc)
    }

    func testCompactionKeepsCurrentQuestionAndOriginalHistoryAndReusesItsCheckpoint() async throws {
        let memory = AgentContextMemory()
        let recorder = SummaryRecorder()
        let original = snapshot()
        let before = original
        let prepared = try await memory.prepare(
            original, intent: "question", scope: "document/provider", budget: .init(), images: [],
            summarize: { await recorder.summarize($0) })
        XCTAssertEqual(original, before, "Compression must never change the displayed or retry history")
        XCTAssertLessThanOrEqual(AgentContextBudget.cost(prepared.messages), AgentContextBudget.defaultLimit)
        let current = try ModelWireFormat.object(Data(XCTUnwrap(prepared.messages.last?.content).utf8))
        XCTAssertEqual(current["request"] as? String, original.question)
        XCTAssertTrue(prepared.messages.contains { $0.content.contains("conversationSummary") })
        let firstCount = await recorder.count
        XCTAssertGreaterThan(firstCount, 0)
        _ = try await memory.prepare(
            original, intent: "question", scope: "document/provider", budget: .init(), images: [],
            summarize: { await recorder.summarize($0) })
        let retryCount = await recorder.count
        XCTAssertEqual(firstCount, retryCount, "Identical histories must not pay to summarize the same prefix again")
        let inputs = await recorder.inputs
        XCTAssertTrue(inputs.allSatisfy { $0.flatMap(\.images).isEmpty })
        XCTAssertTrue(inputs.allSatisfy { AgentContextBudget.cost($0) < AgentContextBudget.defaultLimit })
        XCTAssertTrue(inputs.flatMap { $0 }.contains { $0.content.contains("stopped") })
    }

    func testManyShortTurnsDoNotTriggerAFixedRoundLimit() async throws {
        let memory = AgentContextMemory()
        let recorder = SummaryRecorder()
        var history: [AgentHistoryTurn] = []
        for _ in 0..<80 {
            history.append(.init(role: "user", markdown: "Why?", attachment: nil))
            history.append(.init(role: "assistant", markdown: "Because.", attachment: nil))
        }
        history.append(.init(role: "user", markdown: "Continue", attachment: nil))
        let value = AgentSnapshot(question: "Continue", attachment: nil, history: history)
        let prepared = try await memory.prepare(
            value, intent: "question", scope: "short", budget: .init(), images: [],
            summarize: { await recorder.summarize($0) })
        XCTAssertEqual(prepared.messages.count, history.count + 1)
        let count = await recorder.count
        XCTAssertEqual(count, 0)
    }

    func testChangedHistoryInvalidatesSummaryIncludingUndoState() async throws {
        let memory = AgentContextMemory()
        let recorder = SummaryRecorder()
        let original = snapshot()
        _ = try await memory.prepare(
            original, intent: "question", scope: "same", budget: .init(), images: [],
            summarize: { await recorder.summarize($0) })
        let before = await recorder.count
        var history = original.history
        history[1] = .init(
            role: "assistant", markdown: history[1].markdown, attachment: nil, status: "stopped",
            changes: [.init(before: "old", after: "new", status: "undone")])
        let changed = AgentSnapshot(
            question: original.question, attachment: nil, history: history, document: original.document)
        _ = try await memory.prepare(
            changed, intent: "question", scope: "same", budget: .init(), images: [],
            summarize: { await recorder.summarize($0) })
        let after = await recorder.count
        XCTAssertGreaterThan(after, before)
        let inputs = await recorder.inputs
        XCTAssertTrue(inputs.flatMap { $0 }.contains { $0.content.contains("undone") })
    }

    func testFailedOrCancelledSummaryDoesNotDiscardHistoryOrCommitAnEmptyCheckpoint() async throws {
        for cancelled in [false, true] {
            let memory = AgentContextMemory()
            do {
                _ = try await memory.prepare(
                    snapshot(), intent: "question", scope: "retry", budget: .init(), images: [],
                    summarize: { _ in
                        if cancelled { throw CancellationError() }
                        return String(repeating: "oversized", count: 9000)
                    })
                XCTFail("Invalid summaries must not be used")
            } catch {
                XCTAssertTrue(cancelled ? error is CancellationError : error is ModelError)
            }
            let recorder = SummaryRecorder()
            let prepared = try await memory.prepare(
                snapshot(), intent: "question", scope: "retry", budget: .init(), images: [],
                summarize: { await recorder.summarize($0) })
            XCTAssertEqual(prepared.messages.last?.role, "user")
            let inputs = await recorder.inputs
            XCTAssertTrue(inputs.flatMap { $0 }.contains { $0.content.contains("Please explain concisely in Italian") })
        }
    }

    func testOversizedDocumentIsExplicitlyOnDemandAndUnicodePagingPreservesEveryCharacter() async throws {
        let text = String(repeating: "中文😀 cafe\u{301} 👨‍👩‍👧‍👦🇨🇳\r\n", count: 9000) + "Final conclusion."
        let doc = document(text)
        let value = AgentSnapshot(
            question: "Summarize the whole document", attachment: nil,
            history: [.init(role: "user", markdown: "Summarize the whole document", attachment: nil, document: doc)],
            document: doc)
        let recorder = SummaryRecorder()
        let prepared = try await AgentContextMemory().prepare(
            value, intent: "question", scope: "large", budget: .init(), images: [],
            summarize: { await recorder.summarize($0) })
        XCTAssertTrue(prepared.needsReadingTool)
        let current = try ModelWireFormat.object(Data(XCTUnwrap(prepared.messages.last?.content).utf8))
        let background = try XCTUnwrap(current["background"] as? [String: Any])
        let documents = try XCTUnwrap(background["documents"] as? [[String: Any]])
        XCTAssertNil(documents.first?["content"])
        XCTAssertEqual(documents.first?["availability"] as? String, "read_document")
        let id = try XCTUnwrap(documents.first?["id"] as? String)
        var offset = 0
        var collected = ""
        while true {
            let args = try JSONSerialization.data(withJSONObject: ["documentID": id, "characterOffset": offset])
            let output = try XCTUnwrap(
                prepared.sources.read(
                    .init(id: "read", name: "read_document", arguments: String(decoding: args, as: UTF8.self)),
                    maxBytes: 997))
            let page = try ModelWireFormat.object(Data(output.output.utf8))
            let content = try XCTUnwrap(page["content"] as? String)
            XCTAssertLessThanOrEqual(content.utf8.count, 997)
            collected += content
            guard let next = page["nextCharacterOffset"] as? Int else { break }
            XCTAssertGreaterThan(next, offset)
            offset = next
        }
        XCTAssertEqual(collected, text, "Paging cannot omit, repeat or corrupt Unicode at boundaries")
        let count = await recorder.count
        XCTAssertEqual(count, 0, "A long file alone needs paging, not a fabricated conversation summary")
    }

    func testReadingUsesCharacterPositionsAndCanFindTheEndOfALargeFile() throws {
        let text = "😀中文\n" + String(repeating: "body\n", count: 6000) + "EXACT_TARGET\nTail."
        let result = try AgentContextSources.read(text, arguments: ["query": "EXACT_TARGET"], maxBytes: 64)
        let page = try ModelWireFormat.object(Data(result.output.utf8))
        XCTAssertTrue((page["content"] as? String)?.hasPrefix("EXACT_TARGET") == true)
        XCTAssertEqual(page["complete"] as? Bool, false)
        XCTAssertEqual(page["totalCharacters"] as? Int, text.count)
        XCTAssertNil(page["totalBytes"])
        for arguments: [String: Any] in [
            ["characterOffset": -1], ["characterOffset": true], ["characterOffset": 0.5],
            ["characterOffset": text.count + 1], ["offset": 1], ["path": "/private/file"], ["documentID": 7],
        ] {
            XCTAssertThrowsError(try AgentContextSources.read(text, arguments: arguments, maxBytes: 64))
        }
        let sample = "A👨‍👩‍👧‍👦e\u{301}🇨🇳中文\r\nZ"
        let expected = ["A", "👨‍👩‍👧‍👦", "e\u{301}", "🇨🇳", "中", "文", "\r\n", "Z"]
        XCTAssertEqual(sample.count, expected.count)
        for offset in 0...expected.count {
            let result = try AgentContextSources.read(sample, arguments: ["characterOffset": offset], maxBytes: 64)
            let page = try ModelWireFormat.object(Data(result.output.utf8))
            XCTAssertEqual(page["characterOffset"] as? Int, offset)
            XCTAssertEqual(page["totalCharacters"] as? Int, expected.count)
            XCTAssertEqual(page["content"] as? String, expected.dropFirst(offset).joined())
        }
        let matching = try AgentContextSources.read(sample, arguments: ["query": "👨‍👩‍👧‍👦"], maxBytes: 64)
        let found = try ModelWireFormat.object(Data(matching.output.utf8))
        XCTAssertEqual(found["characterOffset"] as? Int, 1)
        XCTAssertTrue((found["content"] as? String)?.hasPrefix("👨‍👩‍👧‍👦") == true)
        let oversized = try AgentContextSources.read(sample, arguments: ["characterOffset": 1], maxBytes: 4)
        let rejected = try ModelWireFormat.object(Data(oversized.output.utf8))
        XCTAssertEqual(rejected["error"] as? String, "character_too_large")
        XCTAssertNil(rejected["content"], "An oversized character must not be split or produce a nonadvancing page")
    }

    func testSnapshotReadValidationReturnsToolErrorsWithoutRelaxingArguments() throws {
        let text = "😀中文\nDocument."
        let snapshot = snapshot(text)
        let sources = AgentContextSources(snapshot)
        let documentID = AgentContextSources.id(text)
        for invalid: [String: Any] in [
            ["offset": 1], ["characterOffset": -1], ["characterOffset": true], ["characterOffset": 0.5],
            ["characterOffset": text.count + 1], ["query": ""], ["path": "/private/file"],
        ] {
            var args = invalid
            args["documentID"] = documentID
            let data = try JSONSerialization.data(withJSONObject: args)
            let result = try XCTUnwrap(
                sources.read(
                    .init(id: "invalid", name: "read_document", arguments: String(decoding: data, as: UTF8.self)),
                    maxBytes: 64))
            let output = try ModelWireFormat.object(Data(result.output.utf8))
            XCTAssertEqual(output["error"] as? String, "invalid_arguments")
            XCTAssertNil(output["content"], "Rejected input must not read document content")
        }
        let malformed = try XCTUnwrap(
            sources.read(
                .init(id: "malformed", name: "read_document", arguments: "{"), maxBytes: 64))
        XCTAssertEqual(malformed.output, AgentContextSources.invalidReadArguments.output)
    }

    func testBudgetUsesOptionalProviderCapacityAndDoesNotPretendItIsKnown() throws {
        XCTAssertEqual(AgentContextBudget(contextWindow: nil).limit, 65_536)
        XCTAssertEqual(AgentContextBudget(contextWindow: 16_384).limit, 12_288)
        let models = try JSONDecoder().decode(
            [CatalogModel].self,
            from: Data(
                #"[{"id":"known","context_length":32768},{"id":"unknown"},{"id":"invalid","context_window":-1}]"#.utf8))
        XCTAssertEqual(models[0].contextWindow, 32_768)
        XCTAssertNil(models[1].contextWindow)
        XCTAssertNil(models[2].contextWindow)
    }
}
