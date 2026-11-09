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
            original, intent: "question", scope: "document/provider",
            budget: .init(capabilities: .init(contextWindow: 32_768)), images: [],
            summarize: { await recorder.summarize($0) })
        XCTAssertEqual(original, before, "Compression must never change the displayed or retry history")
        XCTAssertLessThanOrEqual(
            AgentContextBudget(capabilities: .init(contextWindow: 32_768)).cost(prepared.messages),
            try XCTUnwrap(AgentContextBudget(capabilities: .init(contextWindow: 32_768)).limit))
        let current = try ModelWireFormat.object(Data(XCTUnwrap(prepared.messages.last?.content).utf8))
        XCTAssertEqual(current["request"] as? String, original.question)
        XCTAssertTrue(prepared.messages.contains { $0.content.contains("conversationSummary") })
        let firstCount = await recorder.count
        XCTAssertGreaterThan(firstCount, 0)
        _ = try await memory.prepare(
            original, intent: "question", scope: "document/provider",
            budget: .init(capabilities: .init(contextWindow: 32_768)), images: [],
            summarize: { await recorder.summarize($0) })
        let retryCount = await recorder.count
        XCTAssertEqual(firstCount, retryCount, "Identical histories must not pay to summarize the same prefix again")
        let inputs = await recorder.inputs
        XCTAssertTrue(inputs.allSatisfy { $0.flatMap(\.images).isEmpty })
        XCTAssertTrue(
            inputs.allSatisfy {
                AgentContextBudget(capabilities: .init(contextWindow: 32_768)).cost($0)
                    <= (AgentContextBudget(capabilities: .init(contextWindow: 32_768)).limit ?? 0)
            })
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
            value, intent: "question", scope: "short", budget: .init(capabilities: .init(contextWindow: 32_768)),
            images: [],
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
            original, intent: "question", scope: "same", budget: .init(capabilities: .init(contextWindow: 32_768)),
            images: [],
            summarize: { await recorder.summarize($0) })
        let before = await recorder.count
        var history = original.history
        history[1] = .init(
            role: "assistant", markdown: history[1].markdown, attachment: nil, status: "stopped",
            changes: [.init(before: "old", after: "new", status: "undone")])
        let changed = AgentSnapshot(
            question: original.question, attachment: nil, history: history, document: original.document)
        _ = try await memory.prepare(
            changed, intent: "question", scope: "same", budget: .init(capabilities: .init(contextWindow: 32_768)),
            images: [],
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
                    snapshot(), intent: "question", scope: "retry",
                    budget: .init(capabilities: .init(contextWindow: 32_768)), images: [],
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
                snapshot(), intent: "question", scope: "retry",
                budget: .init(capabilities: .init(contextWindow: 32_768)), images: [],
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
            value, intent: "question", scope: "large", budget: .init(capabilities: .init(contextWindow: 32_768)),
            images: [],
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
        let unknown = AgentContextBudget()
        XCTAssertNil(unknown.limit)
        XCTAssertNil(unknown.outputLimit(inputCost: 1_000_000))
        XCTAssertTrue(unknown.fits(1_000_000))
        let large = AgentContextBudget(capabilities: .init(contextWindow: 1_050_000, maxOutputTokens: 131_072))
        XCTAssertEqual(large.outputLimit(inputCost: 1000), 131_072)
        XCTAssertEqual(large.outputLimit(inputCost: 950_000), 47_500)
        XCTAssertEqual(large.limit, AgentContextBudget(capabilities: .init(contextWindow: 1_050_000)).limit)
        let inputOnly = AgentContextBudget(capabilities: .init(maxInputTokens: 100_000, maxOutputTokens: 50_000))
        XCTAssertFalse(inputOnly.fits(100_001))
        XCTAssertEqual(inputOnly.outputLimit(inputCost: 90_000), 50_000)
        let models = try JSONDecoder().decode(
            [CatalogModel].self,
            from: Data(
                #"[{"id":"known","context_length":32768},{"id":"unknown"},{"id":"invalid","context_window":-1}]"#.utf8))
        XCTAssertEqual(models[0].contextWindow, 32_768)
        XCTAssertNil(models[1].contextWindow)
        XCTAssertNil(models[2].contextWindow)
    }

    private func longConversation() -> AgentSnapshot {
        let doc = document("# Reading note\n\nCurrent content.")
        var history: [AgentHistoryTurn] = []
        for index in 0..<4 {
            history.append(.init(role: "user", markdown: "Remember decision \(index).", attachment: nil, document: doc))
            history.append(
                .init(
                    role: "assistant",
                    markdown: String(repeating: "A prior conclusion with supporting evidence. ", count: 1000),
                    attachment: nil))
        }
        history.append(.init(role: "user", markdown: "Continue", attachment: nil, document: doc))
        return AgentSnapshot(question: "Continue", attachment: nil, history: history, document: doc)
    }

    func testBatchCompactionUsesOneRequestForMultipleCompleteTurns() async throws {
        let recorder = SummaryRecorder()
        let budget = AgentContextBudget(capabilities: .init(contextWindow: 65_536))
        let prepared = try await AgentContextMemory().prepare(
            longConversation(), intent: "question", scope: "batch", budget: budget, images: [],
            summarize: { await recorder.summarize($0) })
        let calls = await recorder.count
        XCTAssertEqual(calls, 1, "Several complete exchanges that fit the summary request must be batched together")
        let inputs = await recorder.inputs
        XCTAssertTrue(inputs[0].last?.content.contains("Remember decision 0") == true)
        XCTAssertTrue(inputs[0].last?.content.contains("Remember decision 1") == true)
        XCTAssertLessThanOrEqual(budget.cost(prepared.messages), try XCTUnwrap(budget.limit))
        XCTAssertEqual(
            try ModelWireFormat.object(Data(XCTUnwrap(prepared.messages.last?.content).utf8))["request"] as? String,
            "Continue")
    }

    func testLargeModelKeepsLongConversationWithoutArtificialByteCeiling() async throws {
        let recorder = SummaryRecorder()
        let value = longConversation()
        let prepared = try await AgentContextMemory().prepare(
            value, intent: "question", scope: "large-window",
            budget: .init(capabilities: .init(contextWindow: 256_000)), images: [],
            summarize: { await recorder.summarize($0) })
        let calls = await recorder.count
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(prepared.messages.count, value.history.count + 1)
        XCTAssertGreaterThan(prepared.messages.reduce(0) { $0 + $1.content.utf8.count }, 65_536)
        XCTAssertTrue(prepared.messages.last?.content.contains("Current content.") == true)
    }

    func testSummaryCheckpointSurvivesRestartWithoutFreezingModelCapacities() async throws {
        let memory = AgentContextMemory()
        let recorder = SummaryRecorder()
        let value = longConversation()
        await memory.configure(scope: "restored")
        let budget = await memory.budget(capabilities: .init(contextWindow: 65_536, maxOutputTokens: 4096))
        _ = try await memory.prepare(
            value, intent: "question", scope: "restored", budget: budget, images: [],
            summarize: { await recorder.summarize($0) })
        let checkpoint = try JSONDecoder().decode(
            AgentContextMemory.Checkpoint.self,
            from: JSONEncoder().encode(await memory.checkpoint()))
        let restored = AgentContextMemory()
        await restored.configure(scope: "restored", restoring: checkpoint)
        let restoredBudget = await restored.budget(capabilities: .init())
        XCTAssertNil(restoredBudget.capabilities.contextWindow)
        XCTAssertNil(restoredBudget.outputLimit(inputCost: 1000))
        let before = await recorder.count
        let prepared = try await restored.prepare(
            value, intent: "question", scope: "restored",
            budget: restoredBudget, images: [], summarize: { await recorder.summarize($0) })
        let after = await recorder.count
        XCTAssertEqual(before, after)
        XCTAssertTrue(prepared.messages.contains { $0.content.contains("conversationSummary") })
        await restored.configure(scope: "different-provider")
        let reset = await restored.checkpoint()
        XCTAssertNil(reset.summary)
    }

    func testReadPruningKeepsLatestContentAndCompleteDurableJournal() async throws {
        let text = String(repeating: "原文", count: 4000)
        let doc = document(text)
        let value = AgentSnapshot(
            question: "Continue", attachment: nil,
            history: [.init(role: "user", markdown: "Continue", attachment: nil, document: doc)], document: doc)
        let result = try AgentContextSources.read(text, arguments: [:], maxBytes: text.utf8.count).output
        let exchanges = (0..<2).map { index in
            ModelToolExchange(
                turn: ModelTurn(calls: [.init(id: "read-\(index)", name: "read_document", arguments: "{}")]),
                outputs: [.init(id: "read-\(index)", content: result)])
        }
        let recorder = SummaryRecorder()
        let budget = AgentContextBudget(capabilities: .init(contextWindow: 32_768))
        let prepared = try await AgentContextMemory().prepare(
            value, intent: "question", scope: "prune",
            budget: budget, images: [], exchanges: exchanges, summarize: { await recorder.summarize($0) })
        let calls = await recorder.count
        XCTAssertEqual(calls, 0, "Recoverable pages can be pruned locally")
        XCTAssertEqual(exchanges[0].outputs[0].content, result)
        XCTAssertEqual(prepared.exchanges.count, 2)
        let omitted = try ModelWireFormat.object(Data(prepared.exchanges[0].outputs[0].content.utf8))
        XCTAssertNil(omitted["content"])
        XCTAssertEqual(omitted["contentAvailableVia"] as? String, "read_document")
        XCTAssertEqual(prepared.exchanges[1].outputs[0].content, result)
        XCTAssertTrue(prepared.evictedReadIDs.contains("read-0"))
        XCTAssertLessThanOrEqual(
            budget.cost(prepared.messages, exchanges: prepared.exchanges), try XCTUnwrap(budget.limit))
    }

    func testToolCompactionBatchesPairsAndRetainsTheExecutionJournal() async throws {
        let value = AgentSnapshot(
            question: "Continue", attachment: nil,
            history: [.init(role: "user", markdown: "Continue", attachment: nil)])
        let payload = String(repeating: "result ", count: 2500)
        let exchanges = (0..<5).map { index in
            ModelToolExchange(
                turn: ModelTurn(calls: [.init(id: "edit-\(index)", name: "edit_document", arguments: "{}")]),
                outputs: [.init(id: "edit-\(index)", content: payload)])
        }
        let budget = AgentContextBudget(capabilities: .init(contextWindow: 32_768))
        let recorder = SummaryRecorder()
        let prepared = try await AgentContextMemory().prepare(
            value, intent: "question", scope: "tools",
            budget: budget, images: [], exchanges: exchanges, summarize: { await recorder.summarize($0) })
        let calls = await recorder.count
        XCTAssertEqual(calls, 1)
        XCTAssertGreaterThan(prepared.toolMemory.summarizedCount, 1)
        XCTAssertEqual(exchanges.count, 5)
        XCTAssertEqual(exchanges.first?.outputs.first?.content, payload)
        XCTAssertEqual(prepared.exchanges.last?.turn.calls.first?.id, "edit-4")
        XCTAssertTrue(prepared.exchanges.allSatisfy { $0.turn.calls.map(\.id) == $0.outputs.map(\.id) })
        XCTAssertLessThanOrEqual(
            budget.cost(prepared.messages, exchanges: prepared.exchanges), try XCTUnwrap(budget.limit))
    }

    func testUsageCalibrationDoesNotInventOrPersistAModelCapacity() async throws {
        let memory = AgentContextMemory()
        await memory.configure(scope: "first")
        let initial = await memory.budget(capabilities: .init())
        XCTAssertNil(initial.limit)
        await memory.observe(inputTokens: 200, estimatedTokens: 100)
        let calibrated = await memory.budget(capabilities: .init(contextWindow: 200_000))
        XCTAssertEqual(calibrated.tokenScale, 2)
        let unknown = await memory.budget(capabilities: .init())
        XCTAssertNil(unknown.limit)
        XCTAssertNil(unknown.capabilities.contextWindow)
        await memory.configure(scope: "second")
        let different = await memory.budget(capabilities: .init())
        XCTAssertEqual(different.tokenScale, 1)
        XCTAssertNil(different.limit)
    }

    func testTokenEstimateCoversCJKEmojiAndCountsOneProtocolEnvelope() throws {
        XCTAssertGreaterThanOrEqual(AgentContextBudget.textTokens("中文"), 2)
        XCTAssertGreaterThanOrEqual(AgentContextBudget.textTokens("👨‍👩‍👧‍👦"), 4)
        let answer = String(repeating: "answer ", count: 500)
        let item = try JSONSerialization.data(withJSONObject: ["type": "message", "content": answer])
        let exchange = ModelToolExchange(turn: ModelTurn(text: answer, responseItems: [item]), outputs: [])
        XCTAssertEqual(
            AgentContextBudget.estimate([], exchanges: [exchange]),
            AgentContextBudget.textTokens(String(decoding: item, as: UTF8.self)))
        let outputLimited = AgentContextBudget(capabilities: .init(contextWindow: 128_000, maxOutputTokens: 2048))
        XCTAssertEqual(outputLimited.outputLimit(inputCost: 1000), 2048)
    }

    func testCancelledRequestsCannotReplaceAnotherModelsCheckpoint() async throws {
        let memory = AgentContextMemory()
        await memory.configure(scope: "active-provider")
        let stale = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await memory.configure(scope: "obsolete-provider")
            await memory.observe(inputTokens: 100_000, estimatedTokens: 100)
        }
        await stale.value
        let checkpoint = await memory.checkpoint()
        XCTAssertEqual(checkpoint.scope, "active-provider")
        XCTAssertEqual(checkpoint.tokenScale, 1)
    }

    func testUnknownCapacityPreservesALongDocumentAndConversationWithoutSummarizing() async throws {
        let value = snapshot(String(repeating: "完整文档😀\n", count: 20_000))
        let recorder = SummaryRecorder()
        let prepared = try await AgentContextMemory().prepare(
            value, intent: "question", scope: "unknown", budget: .init(), images: [],
            summarize: { await recorder.summarize($0) })
        let count = await recorder.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(prepared.needsReadingTool)
        XCTAssertEqual(prepared.messages.count, value.history.count + 1)
        let user = try ModelWireFormat.object(Data(XCTUnwrap(prepared.messages.last?.content).utf8))
        let background = try XCTUnwrap(user["background"] as? [String: Any])
        let documents = try XCTUnwrap(background["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.first?["content"] as? String, value.document?.markdown)
    }
}
