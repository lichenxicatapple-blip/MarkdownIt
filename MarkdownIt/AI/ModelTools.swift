import Foundation

struct ModelTool: Sendable {
    let name: String
    let description: String
    let parameters: Data
    let reusesResult: Bool

    init(name: String, description: String, parameters: String, reusesResult: Bool = false) {
        self.name = name
        self.description = description
        self.parameters = Data(parameters.utf8)
        self.reusesResult = reusesResult
    }
}

struct ModelToolCall: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let arguments: String
}

struct ModelToolOutput: Codable, Sendable {
    let id: String
    var content: String
    var images: [ModelImage] = []
}

struct ModelTokenUsage: Codable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?

    init?(_ root: [String: Any], api: ModelAPIProtocol) {
        let response = root["response"] as? [String: Any] ?? root
        guard let usage = response["usage"] as? [String: Any] else { return nil }
        let input = usage[api == .responses ? "input_tokens" : "prompt_tokens"] as? Int
        let output = usage[api == .responses ? "output_tokens" : "completion_tokens"] as? Int
        inputTokens = input.flatMap { $0 >= 0 ? $0 : nil }
        outputTokens = output.flatMap { $0 >= 0 ? $0 : nil }
    }
}

struct ModelTurn: Codable, Sendable {
    var text = ""
    var calls: [ModelToolCall] = []
    // Preserve opaque reasoning/signature fields without interpreting or displaying them.
    var responseItems: [Data] = []
    var chatAssistant: Data?
    var usage: ModelTokenUsage?
}

struct ModelToolExchange: Codable, Sendable {
    let turn: ModelTurn
    let outputs: [ModelToolOutput]
}

enum ModelToolWire {
    static func requestBody(
        _ configuration: ModelConfiguration, messages: [ChatMessage],
        tools: [ModelTool], exchanges: [ModelToolExchange], maxOutputTokens: Int? = nil
    ) throws -> Data {
        let responses = configuration.apiProtocol == .responses
        var body: [String: Any] = [
            "model": configuration.model.trimmingCharacters(in: .whitespacesAndNewlines), "stream": true,
        ]
        var input = messages.filter { !responses || $0.role != "system" }
            .map { ModelWireFormat.message($0, api: configuration.apiProtocol) }
        for exchange in exchanges {
            if responses {
                input += try exchange.turn.responseItems.map { try ModelWireFormat.object($0) }
                input += exchange.outputs.map {
                    [
                        "type": "function_call_output", "call_id": $0.id,
                        "output": ModelWireFormat.content($0.content, images: $0.images, api: .responses),
                    ]
                }
            } else {
                guard let assistant = exchange.turn.chatAssistant else { throw ModelError.invalidResponse }
                input.append(try ModelWireFormat.object(assistant))
                input += exchange.outputs.map { ["role": "tool", "tool_call_id": $0.id, "content": $0.content] }
                // Chat tool messages accept text only. Supply their images as
                // following user content, while retaining every tool result ID.
                let images = exchange.outputs.flatMap(\.images)
                if !images.isEmpty {
                    input.append(
                        ModelWireFormat.message(
                            ChatMessage(
                                role: "user", content: "Images returned by the preceding tools.", images: images),
                            api: .chatCompletions))
                }
            }
        }
        body[responses ? "input" : "messages"] = input
        if responses {
            body["instructions"] = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
            body["store"] = false
        }
        body["tools"] = try tools.map { tool -> [String: Any] in
            let function: [String: Any] = [
                "name": tool.name, "description": tool.description, "strict": true,
                "parameters": try ModelWireFormat.object(tool.parameters),
            ]
            return responses
                ? function.merging(["type": "function"], uniquingKeysWith: { a, _ in a })
                : ["type": "function", "function": function]
        }
        body["parallel_tool_calls"] = false
        ModelWireFormat.setOutputLimit(maxOutputTokens, in: &body, configuration: configuration)
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }

    static func complete(_ data: Data, api: ModelAPIProtocol) throws -> ModelTurn {
        let root = try ModelWireFormat.object(data)
        var decoder = ModelToolDecoder()
        let text: String
        if api == .responses {
            try ModelWireFormat.checkCompletion(root)
            guard root["status"] as? String == "completed" else { throw ModelError.invalidResponse }
            decoder.recordResponse(root)
            text = ModelWireFormat.responseText(root)
        } else {
            guard let choice = (root["choices"] as? [[String: Any]])?.first,
                let message = choice["message"] as? [String: Any]
            else { throw ModelError.invalidResponse }
            try ModelWireFormat.checkCompletion(root)
            try ModelWireFormat.checkChatFinish(choice["finish_reason"] as? String, allowsTools: true)
            if !(message["tool_calls"] as? [Any] ?? []).isEmpty {
                guard ["tool_calls", "stop"].contains(choice["finish_reason"] as? String ?? "") else {
                    throw ModelError.invalidResponse
                }
            }
            decoder.recordChatMessage(message)
            text = ModelWireFormat.text(message["content"])
        }
        var turn = try decoder.result(text: text, api: api)
        turn.usage = ModelTokenUsage(root, api: api)
        guard !turn.text.isEmpty || !turn.calls.isEmpty else { throw ModelError.invalidResponse }
        return turn
    }
}

/// Tool arguments are buffered until the entire model turn completes successfully.
/// Incomplete streams never execute partial calls.
struct ModelToolDecoder {
    private var responseItems: [Int: [String: Any]] = [:]
    private var chatCalls: [Int: [String: Any]] = [:]
    private var chatReasoning = ""

    var hasCalls: Bool {
        !chatCalls.isEmpty || responseItems.values.contains { $0["type"] as? String == "function_call" }
    }

    mutating func record(_ root: [String: Any], api: ModelAPIProtocol) {
        if api == .chatCompletions {
            guard let choice = (root["choices"] as? [[String: Any]])?.first,
                let delta = choice["delta"] as? [String: Any]
            else { return }
            chatReasoning += delta["reasoning_content"] as? String ?? ""
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                guard let index = call["index"] as? Int else { continue }
                var existing = chatCalls[index] ?? [:]
                for (key, value) in call where key != "index" && key != "function" {
                    // Continuation chunks can repeat id/type as empty or null placeholders.
                    // Keep the established identity; missing identity still fails at completion.
                    guard !(value is NSNull), (value as? String)?.isEmpty != true else { continue }
                    existing[key] = value
                }
                var function = existing["function"] as? [String: Any] ?? [:]
                let part = call["function"] as? [String: Any] ?? [:]
                if let name = part["name"] as? String { function["name"] = (function["name"] as? String ?? "") + name }
                if let arguments = part["arguments"] as? String {
                    function["arguments"] = (function["arguments"] as? String ?? "") + arguments
                }
                existing["function"] = function
                chatCalls[index] = existing
            }
            return
        }
        switch root["type"] as? String {
        case "response.output_item.added", "response.output_item.done":
            if let index = root["output_index"] as? Int, let item = root["item"] as? [String: Any] {
                responseItems[index] = item
            }
        case "response.function_call_arguments.delta":
            if let index = root["output_index"] as? Int, let delta = root["delta"] as? String,
                var item = responseItems[index]
            {
                item["arguments"] = (item["arguments"] as? String ?? "") + delta
                responseItems[index] = item
            }
        case "response.function_call_arguments.done":
            if let index = root["output_index"] as? Int, let arguments = root["arguments"] as? String,
                var item = responseItems[index]
            {
                item["arguments"] = arguments
                responseItems[index] = item
            }
        case "response.completed":
            if let response = root["response"] as? [String: Any] { recordResponse(response) }
        default: break
        }
    }

    mutating func recordResponse(_ response: [String: Any]) {
        guard let output = response["output"] as? [[String: Any]] else { return }
        responseItems.removeAll()
        for (index, item) in output.enumerated() {
            responseItems[index] = item
        }
    }

    mutating func recordChatMessage(_ message: [String: Any]) {
        chatReasoning = message["reasoning_content"] as? String ?? ""
        for (index, call) in (message["tool_calls"] as? [[String: Any]] ?? []).enumerated() { chatCalls[index] = call }
    }

    func result(text: String, api: ModelAPIProtocol) throws -> ModelTurn {
        var turn = ModelTurn(text: text)
        var ids = Set<String>()
        if api == .responses {
            for index in responseItems.keys.sorted() {
                let item = responseItems[index]!
                turn.responseItems.append(try JSONSerialization.data(withJSONObject: item, options: .sortedKeys))
                if item["type"] as? String == "function_call" {
                    turn.calls.append(try call(id: item["call_id"], function: item, ids: &ids))
                }
            }
        } else {
            var calls: [[String: Any]] = []
            for index in chatCalls.keys.sorted() {
                let item = chatCalls[index]!
                guard let function = item["function"] as? [String: Any], item["type"] as? String == "function" else {
                    throw ModelError.invalidResponse
                }
                turn.calls.append(try call(id: item["id"], function: function, ids: &ids))
                calls.append(item)
            }
            var assistant: [String: Any] = ["role": "assistant", "content": text]
            if !calls.isEmpty { assistant["tool_calls"] = calls }
            if !chatReasoning.isEmpty { assistant["reasoning_content"] = chatReasoning }
            turn.chatAssistant = try JSONSerialization.data(withJSONObject: assistant, options: .sortedKeys)
        }
        return turn
    }

    private func call(id: Any?, function: [String: Any], ids: inout Set<String>) throws -> ModelToolCall {
        guard let id = id as? String, !id.isEmpty, ids.insert(id).inserted,
            let name = function["name"] as? String, !name.isEmpty,
            let arguments = function["arguments"] as? String
        else { throw ModelError.invalidResponse }
        _ = try ModelWireFormat.object(Data(arguments.utf8))
        return ModelToolCall(id: id, name: name, arguments: arguments)
    }
}
