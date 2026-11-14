import Foundation

enum ModelWireFormat {
    static func request(
        _ configuration: ModelConfiguration, messages: [ChatMessage], maxOutputTokens: Int? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": configuration.model.trimmingCharacters(in: .whitespacesAndNewlines), "stream": true,
            "input": messages.filter { $0.role != "system" }.map(message),
            "instructions": messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n"),
            "store": false,
        ]
        if let maxOutputTokens { body["max_output_tokens"] = max(1, maxOutputTokens) }
        return body
    }

    static func requestBody(
        _ configuration: ModelConfiguration, messages: [ChatMessage], maxOutputTokens: Int? = nil
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: request(configuration, messages: messages, maxOutputTokens: maxOutputTokens),
            options: .sortedKeys)
    }

    static func message(_ value: ChatMessage) -> [String: Any] {
        ["role": value.role, "content": content(value.content, images: value.images)]
    }

    static func content(_ text: String, images: [ModelImage]) -> Any {
        guard !images.isEmpty else { return text }
        var parts: [[String: Any]] = [["type": "input_text", "text": text]]
        for image in images {
            parts.append(["type": "input_text", "text": "imageID: " + image.id])
            parts.append(["type": "input_image", "image_url": image.dataURL, "detail": "auto"])
        }
        return parts
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelError.invalidResponse
        }
        return root
    }

    static func responseText(_ root: [String: Any]) -> String {
        (root["output"] as? [[String: Any]] ?? []).compactMap { item -> String? in
            guard item["type"] as? String == "message" else { return nil }
            return (item["content"] as? [[String: Any]] ?? []).compactMap { part in
                if part["type"] as? String == "refusal" { return part["refusal"] as? String }
                guard part["type"] as? String == "output_text" else { return nil }
                return part["text"] as? String
            }.joined()
        }.joined(separator: "\n\n")
    }

    static func checkCompletion(_ root: [String: Any]) throws {
        if root["error"] is [String: Any] { throw serviceFailure(root["error"], fallback: .generationFailed) }
        if ["failed", "cancelled"].contains(root["status"] as? String ?? "") { throw ModelError.generationFailed }
        if root["status"] as? String == "incomplete" { throw ModelError.incomplete }
    }

    static func remoteError(_ value: Any?, fallback: ModelError) -> ModelError {
        let error = value as? [String: Any] ?? [:]
        let description = ["code", "type", "message"].compactMap { error[$0] as? String }.joined(separator: " ")
            .lowercased()
        let code = error["code"] as? String ?? ""
        if ["context_length_exceeded", "context_window_exceeded"].contains(code)
            || [
                "maximum context length", "maximum context exceeded", "input exceeds the context window",
                "prompt is too long",
                "range of input length should be", "total message token length exceed model limit",
            ].contains(
                where: description.contains)
        {
            return .contextLimit
        }
        if description.contains("rate_limit") || error["code"] as? Int == 429 { return .rateLimited(0) }
        if ["invalid_api_key", "authentication_error"].contains(where: description.contains) {
            return .service(401, String(localized: "Authentication failed."))
        }
        return fallback
    }

    static func errorMessage(_ value: Any?) -> String? {
        let error = value as? [String: Any] ?? [:]
        if let message = error["message"] as? String, !message.isEmpty { return message }
        if let code = error["code"] as? String, !code.isEmpty { return code }
        return (error["code"] as? NSNumber)?.stringValue
    }

    static func serviceFailure(_ value: Any?, fallback: ModelError) -> ModelServiceFailure {
        ModelServiceFailure(
            reason: remoteError(value, fallback: fallback), httpStatus: nil, message: errorMessage(value))
    }

    static func completeResponse(_ data: Data) throws -> ModelStreamDecoder.Update {
        let root = try object(data)
        let content = responseText(root)
        var failure: (any Error)?
        do { try checkCompletion(root) } catch { failure = error }
        if failure == nil && root["status"] as? String != "completed" { throw ModelError.invalidResponse }
        guard !content.isEmpty || failure != nil else { throw ModelError.invalidResponse }
        return ModelStreamDecoder.Update(text: content, completed: failure == nil, failure: failure)
    }
}

struct ModelStreamDecoder {
    let allowsTools: Bool
    private(set) var receivedText = false
    private(set) var tools = ModelToolDecoder()
    private(set) var usage: ModelTokenUsage?

    init(allowsTools: Bool = false) { self.allowsTools = allowsTools }

    struct Update {
        var text = ""
        var completed = false
        var failure: (any Error)?
    }

    mutating func consume(_ frame: ServerSentEvents.Event) throws -> Update {
        guard frame.data != "[DONE]" else { throw ModelError.invalidResponse }
        let root = try ModelWireFormat.object(Data(frame.data.utf8))
        if let usage = ModelTokenUsage(root) { self.usage = usage }
        if root["error"] != nil { throw ModelWireFormat.serviceFailure(root["error"], fallback: .generationFailed) }
        if allowsTools { tools.record(root) }
        var update = Update()
        let type = root["type"] as? String ?? root["event"] as? String ?? frame.name
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            update.text = root["delta"] as? String ?? ""
        case "response.completed":
            guard let response = root["response"] as? [String: Any], response["status"] as? String == "completed" else {
                throw ModelError.invalidResponse
            }
            try ModelWireFormat.checkCompletion(response)
            if !receivedText { update.text = ModelWireFormat.responseText(response) }
            update.completed = true
        case "response.incomplete", "response.failed", "error":
            let response = root["response"] as? [String: Any] ?? root
            if !receivedText { update.text = ModelWireFormat.responseText(response) }
            var error = response["error"]
            if error == nil && type == "error" { error = response }
            if error != nil {
                update.failure = ModelWireFormat.serviceFailure(
                    error, fallback: type == "response.incomplete" ? .incomplete : .generationFailed)
            } else {
                update.failure = type == "response.incomplete" ? ModelError.incomplete : ModelError.generationFailed
            }
        default: break
        }
        if !update.text.isEmpty { receivedText = true }
        if update.completed && !receivedText && !(allowsTools && tools.hasCalls) { throw ModelError.invalidResponse }
        return update
    }
}

/// SSE framing across arbitrary network chunks, including CRLF, comments and multiline data.
struct ServerSentEvents {
    struct Event {
        let name: String
        let data: String
    }
    private var line: [UInt8] = []
    private var data: [String] = []
    private var name = ""
    private var size = 0
    private var carriageReturn = false

    mutating func append(_ byte: UInt8) throws -> Event? {
        if byte == 10 && carriageReturn {
            carriageReturn = false
            return nil
        }
        carriageReturn = byte == 13
        if byte == 10 || byte == 13 { return try consumeLine() }
        guard line.count < 2_000_000 else { throw ModelError.invalidResponse }
        line.append(byte)
        return nil
    }

    mutating func finish() throws -> Event? {
        if !line.isEmpty { _ = try consumeLine() }
        return dispatch()
    }

    private mutating func consumeLine() throws -> Event? {
        let value = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if value.isEmpty { return dispatch() }
        if value.hasPrefix(":") { return nil }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var content = parts.count == 2 ? String(parts[1]) : ""
        if content.hasPrefix(" ") { content.removeFirst() }
        switch parts[0] {
        case "event": name = content
        case "data":
            size += content.utf8.count
            guard size <= 2_000_000 else { throw ModelError.invalidResponse }
            data.append(content)
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> Event? {
        defer {
            data.removeAll(keepingCapacity: true)
            name = ""
            size = 0
        }
        guard !data.isEmpty else { return nil }
        return Event(name: name, data: data.joined(separator: "\n"))
    }
}
