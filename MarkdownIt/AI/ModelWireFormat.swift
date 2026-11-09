import Foundation

enum ModelWireFormat {
    static func requestBody(
        _ configuration: ModelConfiguration, messages: [ChatMessage], maxOutputTokens: Int? = nil
    ) throws -> Data {
        let responses = configuration.apiProtocol == .responses
        var body: [String: Any] = [
            "model": configuration.model.trimmingCharacters(in: .whitespacesAndNewlines), "stream": true,
            responses ? "input" : "messages": messages.filter { !responses || $0.role != "system" }
                .map { message($0, api: configuration.apiProtocol) },
        ]
        if responses {
            body["instructions"] = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
            body["store"] = false
        }
        setOutputLimit(maxOutputTokens, in: &body, configuration: configuration)
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }

    static func setOutputLimit(_ tokens: Int?, in body: inout [String: Any], configuration: ModelConfiguration) {
        guard let tokens else { return }
        let host = (try? configuration.endpoint())?.host?.lowercased() ?? ""
        let field =
            configuration.apiProtocol == .responses
            ? "max_output_tokens"
            : (host == "api.deepseek.com" || ModelCatalog.isQwenHost(host)) ? "max_tokens" : "max_completion_tokens"
        body[field] = max(1, tokens)
    }

    static func message(_ value: ChatMessage, api: ModelAPIProtocol) -> [String: Any] {
        ["role": value.role, "content": content(value.content, images: value.images, api: api)]
    }

    static func content(_ text: String, images: [ModelImage], api: ModelAPIProtocol) -> Any {
        guard !images.isEmpty else { return text }
        let responses = api == .responses
        var parts: [[String: Any]] = [["type": responses ? "input_text" : "text", "text": text]]
        for image in images {
            parts.append(["type": responses ? "input_text" : "text", "text": "imageID: " + image.id])
            parts.append(
                responses
                    ? ["type": "input_image", "image_url": image.dataURL, "detail": "auto"]
                    : ["type": "image_url", "image_url": ["url": image.dataURL, "detail": "auto"]])
        }
        return parts
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelError.invalidResponse
        }
        return root
    }

    static func text(_ content: Any?) -> String {
        if let string = content as? String { return string }
        return (content as? [[String: Any]] ?? []).compactMap { part in
            guard ["text", "output_text"].contains(part["type"] as? String ?? "") else { return nil }
            return part["text"] as? String
        }.joined()
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
        if root["error"] is [String: Any] { throw remoteError(root["error"], fallback: .generationFailed) }
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
        if description.contains("rate_limit") { return .rateLimited(0) }
        if ["invalid_api_key", "authentication_error"].contains(where: description.contains) {
            return .service(401, String(localized: "Authentication failed."))
        }
        return fallback
    }

    static func checkChatFinish(_ reason: String?, allowsTools: Bool = false) throws {
        guard let reason, !reason.isEmpty else { return }
        if allowsTools && reason == "tool_calls" { return }
        guard reason == "stop" else {
            if ["length", "content_filter"].contains(reason) { throw ModelError.incomplete }
            throw ModelError.interrupted
        }
    }

    static func completeResponse(_ data: Data, api: ModelAPIProtocol) throws -> ModelStreamDecoder.Update {
        let root = try object(data)
        let content: String
        var failure: ModelError?
        switch api {
        case .responses:
            content = responseText(root)
            do { try checkCompletion(root) } catch let error as ModelError { failure = error }
            if failure == nil && root["status"] as? String != "completed" { throw ModelError.invalidResponse }
        case .chatCompletions:
            let choice = (root["choices"] as? [[String: Any]])?.first
            do {
                try checkCompletion(root)
                try checkChatFinish(choice?["finish_reason"] as? String)
            } catch let error as ModelError { failure = error }
            let message = choice?["message"] as? [String: Any]
            content = text(message?["content"])
        }
        guard !content.isEmpty || failure != nil else { throw ModelError.invalidResponse }
        return ModelStreamDecoder.Update(text: content, completed: failure == nil, failure: failure)
    }
}

struct ModelStreamDecoder {
    let api: ModelAPIProtocol
    let allowsTools: Bool
    private(set) var receivedText = false
    private(set) var tools = ModelToolDecoder()
    private(set) var usage: ModelTokenUsage?

    init(api: ModelAPIProtocol, allowsTools: Bool = false) {
        self.api = api
        self.allowsTools = allowsTools
    }

    struct Update {
        var text = ""
        var completed = false
        var failure: ModelError?
    }

    mutating func consume(_ frame: ServerSentEvents.Event) throws -> Update {
        if frame.data == "[DONE]" {
            guard api == .chatCompletions, receivedText || (allowsTools && tools.hasCalls) else {
                throw ModelError.invalidResponse
            }
            return Update(completed: true)
        }
        let root = try ModelWireFormat.object(Data(frame.data.utf8))
        if let usage = ModelTokenUsage(root, api: api) { self.usage = usage }
        if root["error"] != nil { throw ModelWireFormat.remoteError(root["error"], fallback: .generationFailed) }
        if allowsTools { tools.record(root, api: api) }
        var update = Update()
        switch api {
        case .chatCompletions:
            guard let choice = (root["choices"] as? [[String: Any]])?.first else { return update }
            let delta = choice["delta"] as? [String: Any]
            update.text = ModelWireFormat.text(delta?["content"])
            do {
                try ModelWireFormat.checkChatFinish(choice["finish_reason"] as? String, allowsTools: allowsTools)
            } catch let error as ModelError { update.failure = error }
            // Some compatible providers end at finish_reason without a [DONE] event.
            let finish = choice["finish_reason"] as? String
            update.completed = finish == "stop" || (allowsTools && finish == "tool_calls")
        case .responses:
            let type = root["type"] as? String ?? root["event"] as? String ?? frame.name
            switch type {
            case "response.output_text.delta", "response.refusal.delta":
                update.text = root["delta"] as? String ?? ""
            case "response.completed":
                guard let response = root["response"] as? [String: Any] else { throw ModelError.invalidResponse }
                try ModelWireFormat.checkCompletion(response)
                if !receivedText { update.text = ModelWireFormat.responseText(response) }
                update.completed = true
            case "response.incomplete", "response.failed", "error":
                let response = root["response"] as? [String: Any] ?? root
                if !receivedText { update.text = ModelWireFormat.responseText(response) }
                update.failure = ModelWireFormat.remoteError(
                    response["error"], fallback: type == "response.incomplete" ? .incomplete : .generationFailed)
            default: break  // Created, usage, reasoning and item lifecycle events are not answer text.
            }
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
