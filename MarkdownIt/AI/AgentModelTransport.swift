import Foundation

struct AgentAttachment: Codable, Sendable, Equatable {
    let text: String
    let markdown: String
    let mode: String
    let scope: String?
    let location: String?
    let start: Int?
    let end: Int?
    var documentName: String? = nil
    var documentMarkdown: String? = nil
    var images: [AgentImageReference]? = nil
}

struct AgentSourceChange: Codable, Sendable, Equatable {
    let before: String
    let after: String
    let status: String
}

struct AgentHistoryTurn: Codable, Sendable, Equatable {
    let role: String
    let markdown: String
    let attachment: AgentAttachment?
    var status: String? = nil
    var intent: String? = nil
    var document: AgentAttachment? = nil
    var changes: [AgentSourceChange]? = nil
}

struct AgentSnapshot: Codable, Sendable, Equatable {
    let question: String
    let attachment: AgentAttachment?
    let history: [AgentHistoryTurn]

    var document: AgentAttachment? = nil
    var id: String? = nil

    func messages(intent: String) throws -> [ChatMessage] {
        try AgentContextBuilder.build(self, intent: intent)
    }

}

struct AgentFailure: Codable, Sendable, Equatable {
    let kind: String
    let retryAfterSeconds: TimeInterval?

    init(_ error: any Error) {
        retryAfterSeconds = if case ModelError.rateLimited(let seconds) = error { seconds } else { nil }
        kind =
            switch error {
            case ModelError.configuration: "configuration"
            case ModelError.missingKey: "authentication"
            case ModelError.sharingPermission: "permission"
            case ModelError.rateLimited: "rateLimit"
            case ModelError.service(let status, _) where [401, 403].contains(status): "authentication"
            case ModelError.service(let status, _) where [400, 404, 422].contains(status): "configuration"
            case ModelError.invalidResponse: "response"
            case ModelError.interrupted: "network"
            case ModelError.incomplete: "incomplete"
            case ModelError.contextLimit: "contextLimit"
            case ModelError.contextPreparation: "contextPreparation"
            case ModelError.requestTooLarge: "requestTooLarge"
            case is AgentImageError: "image"
            case let value as CocoaError where value.code == .fileReadNoPermission: "imagePermission"
            case is CocoaError: "image"
            case is ModelError: "service"
            case let value as URLError where value.code == .timedOut: "timeout"
            case is URLError: "network"
            default: "service"
            }
    }
}

struct AgentModelEvent: Encodable, Sendable {
    let id: String
    let token: String
    let type: String
    var text: String?
    var failure: AgentFailure?
    var change: AgentDocumentChange?
    var imageIDs: [String]?
}

/// One model request at a time. The UI supplies immutable turn snapshots, never credentials.
@MainActor
final class AgentModelTransport {
    private static let pausedToolOutput =
        "{\"error\":\"repeated_without_progress\",\"message\":\"相同调用得到相同结果且文档没有变化。已停止继续调用工具，请如实说明结果。\"}"
    private let client: ModelClient
    private var contextMemory = AgentContextMemory()
    private var task: Task<Void, Never>?
    private(set) var activeID: String?
    private final class Run {
        let key: String
        var exchanges: [ModelToolExchange] = []
        var pending: Pending?
        var seenToolResults = Set<String>()
        var toolsPaused = false
        var messages: [ChatMessage]?
        var sources: AgentContextSources?
        var needsReadingTool = false
        var toolSummary: String?
        var readSignatures: [String: String] = [:]
        init(key: String) { self.key = key }
    }
    private final class Pending {
        let turn: ModelTurn
        var outputs: [ModelToolOutput] = []
        init(turn: ModelTurn) { self.turn = turn }
    }
    struct Recovery: Codable, Sendable {
        let key: String
        let exchanges: [ModelToolExchange]
        let pendingTurn: ModelTurn?
        let pendingOutputs: [ModelToolOutput]
        let seenToolResults: Set<String>
        let toolsPaused: Bool
        let messages: [ChatMessage]?
        let sources: AgentContextSources?
        let needsReadingTool: Bool
        let toolSummary: String?
        let readSignatures: [String: String]
    }

    var checkpoint: (@MainActor () async -> Void)?

    func recovery() -> Recovery? {
        guard let run else { return nil }
        return Recovery(
            key: run.key, exchanges: run.exchanges, pendingTurn: run.pending?.turn,
            pendingOutputs: run.pending?.outputs ?? [], seenToolResults: run.seenToolResults,
            toolsPaused: run.toolsPaused, messages: run.messages, sources: run.sources,
            needsReadingTool: run.needsReadingTool, toolSummary: run.toolSummary, readSignatures: run.readSignatures)
    }

    func restore(_ value: Recovery?) throws {
        reset()
        guard let value else { return }
        guard value.pendingOutputs.count <= (value.pendingTurn?.calls.count ?? 0),
            value.pendingOutputs.enumerated().allSatisfy({ value.pendingTurn?.calls[$0.offset].id == $0.element.id })
        else { throw CocoaError(.coderReadCorrupt) }
        let run = Run(key: value.key)
        run.exchanges = value.exchanges
        if let turn = value.pendingTurn {
            run.pending = Pending(turn: turn)
            run.pending?.outputs = value.pendingOutputs
        }
        run.seenToolResults = value.seenToolResults
        run.toolsPaused = value.toolsPaused
        run.messages = value.messages
        run.sources = value.sources
        run.needsReadingTool = value.needsReadingTool
        run.toolSummary = value.toolSummary
        run.readSignatures = value.readSignatures
        self.run = run
    }

    private var run: Run?

    init(client: ModelClient = ModelClient()) { self.client = client }
    deinit { task?.cancel() }

    func cancel(id: String? = nil) {
        guard id == nil || id == activeID else { return }
        activeID = nil
        task?.cancel()
        task = nil
    }

    func reset() {
        cancel()
        run = nil
        contextMemory = AgentContextMemory()
    }

    func start(
        id: String, token: String, snapshot: AgentSnapshot, intent: String,
        configuration: ModelConfiguration, key: String, contextWindow: Int? = nil,
        toolsAvailable: @escaping @MainActor () -> Bool = { false },
        prepareImages: @escaping @MainActor () async throws -> [ModelImage] = { [] },
        imageTools: @escaping @MainActor () -> [ModelTool] = { [] },
        readDocument: (@MainActor (ModelToolCall, Int) async -> AgentToolExecution)? = nil,
        executeTool:
            @escaping @MainActor (
                ModelToolCall, @escaping @MainActor (AgentDocumentChange) async -> Void
            ) async -> AgentToolExecution = { _, _ in AgentToolExecution(output: "{\"error\":\"read_only\"}") },
        emit: @escaping @MainActor (AgentModelEvent) async -> Void
    ) {
        guard activeID == nil else { return }
        activeID = id
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let scope =
            token + ":" + configuration.baseURL + ":" + configuration.model + ":"
            + configuration.apiProtocol.rawValue + ":" + AgentDocumentTools.revision(key)
        let requestKey =
            AgentDocumentTools.revision(scope) + ":"
            + AgentDocumentTools.revision(
                String(decoding: (try? encoder.encode(snapshot)) ?? Data(), as: UTF8.self))
        let currentRun = run?.key == requestKey ? run! : Run(key: requestKey)
        run = currentRun
        let imageIDs = Set(
            snapshot.history.flatMap {
                (($0.document?.images ?? []) + ($0.attachment?.images ?? [])).map(\.id)
            })
        let memory = contextMemory
        task = Task { [weak self, client, memory] in
            guard !Task.isCancelled else { return }
            await memory.configure(scope: scope)
            let budget = await memory.budget(contextWindow: contextWindow)
            let summarize: AgentContextMemory.Summarize = { messages in
                let turn = try await client.stream(configuration: configuration, key: key, messages: messages) { _ in }
                guard turn.calls.isEmpty else { throw ModelError.contextPreparation }
                return turn.text
            }
            do {
                if currentRun.messages == nil {
                    let images = try await prepareImages()
                    let prepared = try await memory.prepare(
                        snapshot, intent: intent, scope: scope, budget: budget, images: images, summarize: summarize)
                    try Task.checkCancellation()
                    currentRun.messages = prepared.messages
                    currentRun.sources = prepared.sources
                    currentRun.needsReadingTool = prepared.needsReadingTool
                    await self?.checkpoint?()
                }
                while true {
                    try Task.checkCancellation()
                    if let pending = currentRun.pending {
                        while pending.outputs.count < pending.turn.calls.count {
                            try Task.checkCancellation()
                            let call = pending.turn.calls[pending.outputs.count]
                            let execution: AgentToolExecution
                            if currentRun.toolsPaused {
                                execution = AgentToolExecution(output: Self.pausedToolOutput)
                            } else if call.name == "read_document",
                                let material = try currentRun.sources?.read(call, maxBytes: budget.limit / 12)
                            {
                                execution = material
                            } else if call.name == "read_document", let readDocument {
                                execution = await readDocument(call, budget.limit / 12)
                            } else if ["read_image", "read_document"].contains(call.name)
                                || (snapshot.document?.mode == "source" && toolsAvailable())
                            {
                                execution = await executeTool(call) { change in
                                    await emit(AgentModelEvent(id: id, token: token, type: "change", change: change))
                                }
                            } else {
                                execution = AgentToolExecution(
                                    output: "{\"error\":\"read_only\",\"message\":\"请切换到源码模式后再修改。\"}")
                            }
                            // Journal successful effects before observing cancellation. A retry
                            // resumes after these results instead of executing the same edit twice.
                            let arguments =
                                (try? JSONSerialization.data(
                                    withJSONObject: ModelWireFormat.object(Data(call.arguments.utf8)),
                                    options: .sortedKeys)) ?? Data(call.arguments.utf8)
                            let signature = AgentDocumentTools.revision(
                                call.name + String(decoding: arguments, as: UTF8.self) + execution.output
                                    + (execution.revision ?? ""))
                            let repeated = !currentRun.seenToolResults.insert(signature).inserted
                            if ["read_document", "read_image"].contains(call.name) {
                                currentRun.readSignatures[call.id] = signature
                            }
                            if repeated { currentRun.toolsPaused = true }
                            pending.outputs.append(
                                ModelToolOutput(
                                    id: call.id,
                                    content: repeated ? Self.pausedToolOutput : execution.output,
                                    images: repeated ? [] : execution.images))
                            await self?.checkpoint?()
                            if let change = execution.change {
                                await emit(AgentModelEvent(id: id, token: token, type: "change", change: change))
                            }
                        }
                        currentRun.exchanges.append(ModelToolExchange(turn: pending.turn, outputs: pending.outputs))
                        currentRun.pending = nil
                    }
                    try Task.checkCancellation()
                    @MainActor func offeredTools() -> [ModelTool] {
                        guard !currentRun.toolsPaused else { return [] }
                        let visibleImages = Set(
                            (currentRun.messages ?? []).flatMap { $0.images.map(\.id) }
                                + currentRun.exchanges.flatMap { $0.outputs.flatMap { $0.images.map(\.id) } })
                        let needsImages = !imageIDs.isSubset(of: visibleImages)
                        return (needsImages ? imageTools() : [])
                            + (snapshot.document?.mode == "source" && toolsAvailable()
                                ? AgentDocumentTools.definitions
                                : currentRun.needsReadingTool ? [AgentDocumentTools.definitions[0]] : [])
                    }
                    var tools = offeredTools()
                    var messages = try Self.messages(currentRun)
                    while AgentContextBudget.cost(messages, exchanges: currentRun.exchanges, tools: tools)
                        > budget.limit
                    {
                        guard let oldest = currentRun.exchanges.first else { throw ModelError.contextLimit }
                        let record = try JSONSerialization.data(
                            withJSONObject: [
                                "answer": oldest.turn.text,
                                "calls": oldest.turn.calls.map { ["name": $0.name, "arguments": $0.arguments] },
                                "results": oldest.outputs.map {
                                    ["content": $0.content, "imageIDs": $0.images.map(\.id)] as [String: Any]
                                },
                            ], options: .sortedKeys)
                        let summary = try await AgentContextMemory.summarize(
                            [String(decoding: record, as: UTF8.self)], previous: currentRun.toolSummary,
                            budget: budget, using: summarize)
                        try Task.checkCancellation()
                        currentRun.toolSummary = summary
                        currentRun.exchanges.removeFirst()
                        for call in oldest.turn.calls {
                            if let signature = currentRun.readSignatures.removeValue(forKey: call.id) {
                                currentRun.seenToolResults.remove(signature)
                            }
                        }
                        messages = try Self.messages(currentRun)
                        tools = offeredTools()
                    }
                    let turn = try await client.stream(
                        configuration: configuration, key: key, messages: messages,
                        tools: tools, exchanges: currentRun.exchanges
                    ) { [weak self] chunk in
                        guard await self?.activeID == id else { return }
                        await emit(AgentModelEvent(id: id, token: token, type: "text", text: chunk))
                    }
                    try Task.checkCancellation()
                    guard !tools.isEmpty || turn.calls.isEmpty else { throw ModelError.invalidResponse }
                    if turn.calls.isEmpty {
                        await emit(AgentModelEvent(id: id, token: token, type: "complete"))
                        break
                    }
                    currentRun.pending = Pending(turn: turn)
                    await self?.checkpoint?()
                }
            } catch {
                if self?.activeID == id && !Task.isCancelled {
                    if case ModelError.contextLimit = error {
                        await memory.reduceBudget()
                        currentRun.messages = nil
                    }
                    await emit(AgentModelEvent(id: id, token: token, type: "failure", failure: AgentFailure(error)))
                }
            }
            if Task.isCancelled { await emit(AgentModelEvent(id: id, token: token, type: "cancelled")) }
            guard let self, self.activeID == id else { return }
            self.activeID = nil
            self.task = nil
        }
    }

    private static func messages(_ run: Run) throws -> [ChatMessage] {
        guard var messages = run.messages else { throw ModelError.invalidResponse }
        if let summary = run.toolSummary {
            let data = try JSONSerialization.data(withJSONObject: ["toolHistorySummary": summary], options: .sortedKeys)
            messages.insert(
                ChatMessage(role: "user", content: String(decoding: data, as: UTF8.self)), at: messages.count - 1)
        }
        return messages
    }
}
