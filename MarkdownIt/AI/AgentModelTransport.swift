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
    var searchResults: [Int: [WebSearchResult]]? = nil
    var webPages: [Int: [WebPageExcerpt]]? = nil

    func messages(intent: String) throws -> [ChatMessage] {
        try AgentContextBuilder.build(self, intent: intent)
    }

}

struct AgentFailure: Codable, Sendable, Equatable {
    let kind: String
    let retryAfterSeconds: TimeInterval?
    let message: String?

    init(_ error: any Error) {
        let reason: any Error = (error as? ModelServiceFailure)?.reason ?? error
        retryAfterSeconds = if case ModelError.rateLimited(let seconds) = reason { seconds } else { nil }
        message =
            if error is ModelServiceFailure {
                error.localizedDescription
            } else if case ModelError.service = error {
                error.localizedDescription
            } else if let error = error as? ModelConfigurationError { error.localizedDescription } else { nil }
        kind =
            switch reason {
            case ModelError.configuration, is ModelConfigurationError: "configuration"
            case ModelError.missingKey: "authentication"
            case ModelError.sharingPermission: "permission"
            case ModelError.rateLimited: "rateLimit"
            case ModelError.service(let status, _) where status == 401: "authentication"
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
    private var contextCheckpoint: AgentContextMemory.Checkpoint?
    private var searchHistory = AgentWebSearchHistory()
    private var task: Task<Void, Never>?
    private(set) var activeID: String?
    private final class Run {
        let key: String
        var exchanges: [ModelToolExchange] = []
        var pending: Pending?
        var seenToolResults = Set<String>()
        var toolsPaused = false
        var sources: AgentContextSources?
        var context = AgentContextMemory.ToolMemory()
        var readSignatures: [String: String] = [:]
        init(key: String) { self.key = key }

        func completedOutput(for call: ModelToolCall) -> String? {
            func arguments(_ value: String) -> Data? {
                guard let object = try? ModelWireFormat.object(Data(value.utf8)) else { return nil }
                return try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            }
            guard let expected = arguments(call.arguments) else { return nil }
            let completed = exchanges + (pending.map { [ModelToolExchange(turn: $0.turn, outputs: $0.outputs)] } ?? [])
            for exchange in completed.reversed() {
                for previous in exchange.turn.calls
                where previous.name == call.name && arguments(previous.arguments) == expected {
                    if let output = exchange.outputs.first(where: { $0.id == previous.id }) { return output.content }
                }
            }
            return nil
        }
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
        let context: AgentContextMemory.Checkpoint?
        let toolMemory: AgentContextMemory.ToolMemory?
        let readSignatures: [String: String]
        var searchHistory: AgentWebSearchHistory? = nil
    }

    var checkpoint: (@MainActor () async -> Void)?

    func recovery() -> Recovery? {
        guard let run else { return nil }
        return Recovery(
            key: run.key, exchanges: run.exchanges, pendingTurn: run.pending?.turn,
            pendingOutputs: run.pending?.outputs ?? [], seenToolResults: run.seenToolResults,
            toolsPaused: run.toolsPaused, context: contextCheckpoint, toolMemory: run.context,
            readSignatures: run.readSignatures, searchHistory: searchHistory)
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
        run.context = value.toolMemory ?? AgentContextMemory.ToolMemory()
        contextCheckpoint = value.context
        searchHistory = value.searchHistory ?? AgentWebSearchHistory()
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

    /// Finish any native tool journal before the document is handed off or closed.
    func stop() async {
        let pending = task
        cancel()
        await pending?.value
    }

    func reset() {
        cancel()
        run = nil
        contextMemory = AgentContextMemory()
        contextCheckpoint = nil
        searchHistory = AgentWebSearchHistory()
    }

    func recordSearch(_ result: WebSearchResult, snapshot: AgentSnapshot) {
        searchHistory.append(result, snapshot: snapshot)
    }

    func recordWebPage(_ page: WebPageExcerpt, snapshot: AgentSnapshot) {
        searchHistory.append(page, snapshot: snapshot)
    }

    func start(
        id: String, token: String, snapshot: AgentSnapshot, intent: String,
        configuration: ModelConfiguration, key: String,
        toolScope: String = "", conversationID: String? = nil,
        capabilities: @escaping @MainActor () async -> ModelCapabilities = { ModelCapabilities() },
        toolsAvailable: @escaping @MainActor () -> Bool = { false },
        prepareImages: @escaping @MainActor () async throws -> [ModelImage] = { [] },
        additionalTools: @escaping @MainActor () -> [ModelTool] = { [] },
        readDocument: (@MainActor (ModelToolCall, Int) async -> AgentToolExecution)? = nil,
        executeTool:
            @escaping @MainActor (
                ModelToolCall, Int, @escaping @MainActor (AgentDocumentChange) async -> Void
            ) async throws -> AgentToolExecution = { _, _, _ in AgentToolExecution(output: "{\"error\":\"read_only\"}")
            },
        emit: @escaping @MainActor (AgentModelEvent) async -> Void
    ) {
        guard activeID == nil else { return }
        activeID = id
        var snapshot = snapshot
        // This material is owned by native execution, never trusted from a Web payload.
        snapshot.searchResults = searchHistory.results(for: snapshot)
        snapshot.webPages = searchHistory.pages(for: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let scope = AgentDocumentTools.revision(
            (conversationID ?? token) + ":" + configuration.baseURL + ":" + configuration.model + ":"
                + "responses" + ":" + AgentDocumentTools.revision(key)
                + (toolScope.isEmpty ? "" : ":" + toolScope))
        let requestKey =
            scope + ":"
            + AgentDocumentTools.revision(
                String(decoding: (try? encoder.encode(snapshot)) ?? Data(), as: UTF8.self))
        let currentRun = run?.key == requestKey ? run! : Run(key: requestKey)
        run = currentRun
        let imageIDs = Set(
            snapshot.history.flatMap {
                (($0.document?.images ?? []) + ($0.attachment?.images ?? [])).map(\.id)
            })
        let memory = contextMemory
        let diagnosticContext = ModelDiagnostics.Context(runID: UUID().uuidString.lowercased())
        task = Task { [weak self, client, memory] in
            guard !Task.isCancelled else { return }
            client.diagnostics.run("run.start", context: diagnosticContext)
            var outcome = "completed"
            defer { client.diagnostics.run("run.end", context: diagnosticContext, outcome: outcome) }
            await memory.configure(scope: scope, restoring: self?.contextCheckpoint)
            do {
                let limits = await capabilities()
                try Task.checkCancellation()
                let images = try await prepareImages()
                currentRun.sources = AgentContextSources(snapshot)
                while true {
                    try Task.checkCancellation()
                    let readBudget = await memory.budget(capabilities: limits)
                    if let pending = currentRun.pending {
                        while pending.outputs.count < pending.turn.calls.count {
                            try Task.checkCancellation()
                            let call = pending.turn.calls[pending.outputs.count]
                            let toolStarted = ContinuousClock.now
                            var toolOutcome = "interrupted"
                            client.diagnostics.tool(
                                "tool.start", context: diagnosticContext, call: call, started: toolStarted, key: key)
                            defer {
                                client.diagnostics.tool(
                                    "tool.end", context: diagnosticContext, call: call, started: toolStarted,
                                    key: key, outcome: toolOutcome)
                            }
                            let execution: AgentToolExecution
                            if currentRun.toolsPaused {
                                execution = AgentToolExecution(output: Self.pausedToolOutput)
                            } else if additionalTools().contains(where: { $0.name == call.name && $0.reusesResult }),
                                let output = currentRun.completedOutput(for: call)
                            {
                                execution = AgentToolExecution(output: output)
                            } else if call.name == "read_document",
                                let material = currentRun.sources?.read(call, maxBytes: readBudget.readByteLimit)
                            {
                                execution = material
                            } else if call.name == "read_document", let readDocument {
                                execution = await readDocument(call, readBudget.readByteLimit)
                            } else if additionalTools().contains(where: { $0.name == call.name })
                                || ["read_image", "read_document"].contains(call.name)
                                || (snapshot.document?.mode == "source" && toolsAvailable())
                            {
                                execution = try await executeTool(call, readBudget.readByteLimit) { change in
                                    await emit(AgentModelEvent(id: id, token: token, type: "change", change: change))
                                }
                            } else if call.name == "edit_document" {
                                execution = AgentToolExecution(
                                    output: "{\"error\":\"read_only\",\"message\":\"请切换到源码模式后再修改。\"}")
                            } else {
                                execution = AgentToolExecution(
                                    output:
                                        #"{"error":"tool_unavailable","message":"Use only the tools available for this request."}"#
                                )
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
                            toolOutcome =
                                repeated ? "repeated_without_progress" : ModelDiagnostics.toolOutcome(execution)
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
                    let budget = await memory.budget(capabilities: limits)
                    let summarize: AgentContextMemory.Summarize = { messages in
                        let turn = try await Self.request(
                            client, configuration: configuration, key: key, messages: messages,
                            budget: budget, memory: memory,
                            context: ModelDiagnostics.Context(runID: diagnosticContext.runID, purpose: .summary)
                        ) { _ in }
                        guard turn.calls.isEmpty else { throw ModelError.contextPreparation }
                        return turn.text
                    }
                    let potentialTools =
                        currentRun.toolsPaused
                        ? []
                        : additionalTools()
                            + (snapshot.document?.mode == "source" && toolsAvailable()
                                ? AgentDocumentTools.definitions : [AgentDocumentTools.definitions[0]])
                    let prepared = try await memory.prepare(
                        snapshot, intent: intent, scope: scope, budget: budget, images: images,
                        tools: potentialTools, exchanges: currentRun.exchanges, toolMemory: currentRun.context,
                        onCheckpoint: { [weak self] state, projection in
                            await self?.rememberContext(state, projection: projection, id: id, key: requestKey)
                        }, summarize: summarize)
                    try Task.checkCancellation()
                    currentRun.sources = prepared.sources
                    currentRun.context = prepared.toolMemory
                    for callID in prepared.evictedReadIDs {
                        if let signature = currentRun.readSignatures.removeValue(forKey: callID) {
                            currentRun.seenToolResults.remove(signature)
                        }
                    }
                    let visibleImages = Set(
                        prepared.messages.flatMap { $0.images.map(\.id) }
                            + prepared.exchanges.flatMap { $0.outputs.flatMap { $0.images.map(\.id) } })
                    let tools = potentialTools.filter {
                        ($0.name != "read_image" || !imageIDs.isSubset(of: visibleImages))
                            && ($0.name != "read_document" || snapshot.document?.mode == "source"
                                || prepared.needsReadingTool)
                    }
                    let turn = try await Self.request(
                        client, configuration: configuration, key: key, messages: prepared.messages,
                        tools: tools, exchanges: prepared.exchanges, budget: budget, memory: memory,
                        context: diagnosticContext
                    ) { [weak self] chunk in
                        guard await self?.activeID == id else { return }
                        await emit(AgentModelEvent(id: id, token: token, type: "text", text: chunk))
                    }
                    try Task.checkCancellation()
                    self?.contextCheckpoint = await memory.checkpoint()
                    guard !tools.isEmpty || turn.calls.isEmpty else { throw ModelError.invalidResponse }
                    if turn.calls.isEmpty {
                        await emit(AgentModelEvent(id: id, token: token, type: "complete"))
                        break
                    }
                    currentRun.pending = Pending(turn: turn)
                    await self?.checkpoint?()
                }
            } catch {
                outcome = ModelDiagnostics.outcome(error)
                if self?.activeID == id && !Task.isCancelled {
                    self?.contextCheckpoint = await memory.checkpoint()
                    await self?.checkpoint?()
                    await emit(AgentModelEvent(id: id, token: token, type: "failure", failure: AgentFailure(error)))
                }
            }
            if Task.isCancelled {
                outcome = "cancelled"
                await emit(AgentModelEvent(id: id, token: token, type: "cancelled"))
            }
            guard let self, self.activeID == id else { return }
            self.activeID = nil
            self.task = nil
        }
    }

    private nonisolated static func request(
        _ client: ModelClient, configuration: ModelConfiguration, key: String, messages: [ChatMessage],
        tools: [ModelTool] = [], exchanges: [ModelToolExchange] = [],
        budget: AgentContextBudget, memory: AgentContextMemory,
        context: ModelDiagnostics.Context,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> ModelTurn {
        let turn = try await client.stream(
            configuration: configuration, key: key, messages: messages, tools: tools, exchanges: exchanges,
            maxOutputTokens: budget.outputLimit(inputCost: budget.cost(messages, exchanges: exchanges, tools: tools)),
            context: context,
            onText: onText)
        await memory.observe(
            inputTokens: turn.usage?.inputTokens,
            estimatedTokens: AgentContextBudget.estimate(messages, exchanges: exchanges, tools: tools))
        return turn
    }

    private func rememberContext(
        _ state: AgentContextMemory.Checkpoint, projection: AgentContextMemory.ToolMemory, id: String, key: String
    ) async {
        guard activeID == id, let run, run.key == key else { return }
        contextCheckpoint = state
        run.context = projection
        await checkpoint?()
    }
}
