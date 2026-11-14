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

    init?(_ root: [String: Any]) {
        let response = root["response"] as? [String: Any] ?? root
        guard let usage = response["usage"] as? [String: Any] else { return nil }
        let input = usage["input_tokens"] as? Int
        let output = usage["output_tokens"] as? Int
        inputTokens = input.flatMap { $0 >= 0 ? $0 : nil }
        outputTokens = output.flatMap { $0 >= 0 ? $0 : nil }
    }
}

struct ModelTurn: Codable, Sendable {
    var text = ""
    var calls: [ModelToolCall] = []
    // Preserve opaque reasoning/signature fields without interpreting or displaying them.
    var responseItems: [Data] = []
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
        var body = ModelWireFormat.request(configuration, messages: messages, maxOutputTokens: maxOutputTokens)
        var input = messages.filter { $0.role != "system" }.map(ModelWireFormat.message)
        for exchange in exchanges {
            input += try exchange.turn.responseItems.map { try ModelWireFormat.object($0) }
            input += exchange.outputs.map {
                [
                    "type": "function_call_output", "call_id": $0.id,
                    "output": ModelWireFormat.content($0.content, images: $0.images),
                ]
            }
        }
        body["input"] = input
        body["tools"] = try tools.map {
            [
                "type": "function", "name": $0.name, "description": $0.description, "strict": true,
                "parameters": try ModelWireFormat.object($0.parameters),
            ]
        }
        body["parallel_tool_calls"] = false
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }

    static func complete(_ data: Data) throws -> ModelTurn {
        let root = try ModelWireFormat.object(data)
        try ModelWireFormat.checkCompletion(root)
        guard root["status"] as? String == "completed" else { throw ModelError.invalidResponse }
        var decoder = ModelToolDecoder()
        decoder.recordResponse(root)
        var turn = try decoder.result(text: ModelWireFormat.responseText(root))
        turn.usage = ModelTokenUsage(root)
        guard !turn.text.isEmpty || !turn.calls.isEmpty else { throw ModelError.invalidResponse }
        return turn
    }
}

/// Tool arguments are buffered until the entire model turn completes successfully.
/// Incomplete streams never execute partial calls.
struct ModelToolDecoder {
    private var responseItems: [Int: [String: Any]] = [:]

    var hasCalls: Bool {
        responseItems.values.contains { $0["type"] as? String == "function_call" }
    }

    mutating func record(_ root: [String: Any]) {
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

    func result(text: String) throws -> ModelTurn {
        var turn = ModelTurn(text: text)
        var ids = Set<String>()
        for index in responseItems.keys.sorted() {
            let item = responseItems[index]!
            turn.responseItems.append(try JSONSerialization.data(withJSONObject: item, options: .sortedKeys))
            if item["type"] as? String == "function_call" {
                turn.calls.append(try call(id: item["call_id"], function: item, ids: &ids))
            }
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
