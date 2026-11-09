import Foundation

/// A single explicit protocol per request. No model probes, protocol fallback or automatic retries.
struct ModelClient: Sendable {
    var session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 90
        self.session = session ?? URLSession(configuration: configuration)
    }

    @discardableResult
    func stream(
        configuration: ModelConfiguration, key: String, messages: [ChatMessage],
        tools: [ModelTool] = [], exchanges: [ModelToolExchange] = [],
        maxOutputTokens: Int? = nil,
        onText: @Sendable (String) async -> Void
    ) async throws -> ModelTurn {
        let endpoint = try configuration.endpoint()
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelError.missingKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        request.setValue(version.map { "MarkdownIt/" + $0 } ?? "MarkdownIt", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let allowsTools = !tools.isEmpty || !exchanges.isEmpty
        request.httpBody =
            try allowsTools
            ? ModelToolWire.requestBody(
                configuration, messages: messages, tools: tools, exchanges: exchanges, maxOutputTokens: maxOutputTokens)
            : ModelWireFormat.requestBody(configuration, messages: messages, maxOutputTokens: maxOutputTokens)
        let (bytes, response) = try await session.bytes(for: request, delegate: ModelRequestPolicy.shared)
        guard let http = response as? HTTPURLResponse else { throw ModelError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes.prefix(8192) { data.append(byte) }
            if http.statusCode == 429 {
                throw ModelError.rateLimited(Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
            }
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            // Atlas uses code/msg; OpenAI-compatible providers commonly use error.message.
            let error =
                root?["error"] as? [String: Any]
                ?? root.map { ["code": $0["code"] ?? "", "message": $0["msg"] ?? ""] }
            let message =
                (error?["message"] as? String
                ?? String(localized: "Check the service URL, credentials, API type, and model."))
                .replacingOccurrences(of: key, with: "••••••")
            throw ModelWireFormat.remoteError(
                error,
                fallback: http.statusCode == 413
                    ? .requestTooLarge : .service(http.statusCode, String(message.prefix(500))))
        }
        if http.mimeType == "application/json" {
            var data = Data()
            for try await byte in bytes.prefix(2_000_001) { data.append(byte) }
            guard data.count <= 2_000_000 else { throw ModelError.invalidResponse }
            if allowsTools {
                let turn = try ModelToolWire.complete(data, api: configuration.apiProtocol)
                try Task.checkCancellation()
                if !turn.text.isEmpty { await onText(turn.text) }
                return turn
            }
            let update = try ModelWireFormat.completeResponse(data, api: configuration.apiProtocol)
            try Task.checkCancellation()
            if !update.text.isEmpty { await onText(update.text) }
            if let failure = update.failure { throw failure }
            return ModelTurn(
                text: update.text,
                usage: ModelTokenUsage(try ModelWireFormat.object(data), api: configuration.apiProtocol))
        }
        var frames = ServerSentEvents()
        var decoder = ModelStreamDecoder(api: configuration.apiProtocol, allowsTools: allowsTools)
        var text = ""
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let frame = try frames.append(byte) else { continue }
            let update = try decoder.consume(frame)
            if !update.text.isEmpty {
                text += update.text
                await onText(update.text)
            }
            if let failure = update.failure { throw failure }
            if update.completed {
                var turn = try decoder.tools.result(text: text, api: configuration.apiProtocol)
                turn.usage = decoder.usage
                return turn
            }
        }
        if let frame = try frames.finish() {
            let update = try decoder.consume(frame)
            if !update.text.isEmpty {
                text += update.text
                await onText(update.text)
            }
            if let failure = update.failure { throw failure }
            if update.completed {
                var turn = try decoder.tools.result(text: text, api: configuration.apiProtocol)
                turn.usage = decoder.usage
                return turn
            }
        }
        throw decoder.receivedText || decoder.tools.hasCalls ? ModelError.interrupted : ModelError.invalidResponse
    }

    private static func retryDelay(_ header: String?) -> TimeInterval {
        guard let header else { return 0 }
        if let seconds = Double(header), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return max(0, formatter.date(from: header)?.timeIntervalSinceNow ?? 0)
    }
}
