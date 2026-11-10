import Foundation
import OSLog

/// Local technical events. Request/response content and credentials have no log fields.
struct ModelDiagnostics: Sendable {
    enum Purpose: String, Codable, Sendable { case answer, summary }
    struct Context: Sendable {
        let runID: String
        var purpose: Purpose = .answer
    }
    struct Event: Codable, Sendable {
        let name: String
        var runID: String?
        var requestID: String?
        var purpose: Purpose?
        var api: String?
        var service: String?
        var model: String?
        var elapsedMS: Int?
        var httpStatus: Int?
        var providerRequestID: String?
        var providerCode: String?
        var providerType: String?
        var retryAfterSeconds: TimeInterval?
        var requestBytes: Int?
        var maxOutputTokens: Int?
        var messageCount: Int?
        var exchangeCount: Int?
        var toolCount: Int?
        var inputTokens: Int?
        var outputTokens: Int?
        var outcome: String?
        var tool: String?
        var toolID: String?
        var argumentBytes: Int?
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MarkdownIt", category: "AI")
    var record: @Sendable (Event) -> Void = { event in
        guard let data = try? JSONEncoder().encode(event) else { return }
        Self.logger.notice("\(String(decoding: data, as: UTF8.self), privacy: .public)")
    }

    struct Request: Sendable {
        let context: Context
        let id = UUID().uuidString.lowercased()
        let started = ContinuousClock.now
        let diagnostics: ModelDiagnostics

        func emit(_ name: String, configure: (inout Event) -> Void = { _ in }) {
            var event = Event(name: name, runID: context.runID, requestID: id, purpose: context.purpose)
            event.elapsedMS = ModelDiagnostics.elapsed(since: started)
            configure(&event)
            diagnostics.record(event)
        }

        func response(_ response: HTTPURLResponse, retryAfter: TimeInterval, key: String) {
            emit("request.response") {
                $0.httpStatus = response.statusCode
                $0.retryAfterSeconds = retryAfter > 0 ? retryAfter : nil
                $0.providerRequestID = ModelDiagnostics.identifier(
                    response.value(forHTTPHeaderField: "x-request-id")
                        ?? response.value(forHTTPHeaderField: "request-id"), redacting: key)
            }
        }

        func remoteError(_ error: [String: Any]?, key: String) {
            emit("request.remote_error") {
                $0.providerCode = ModelDiagnostics.identifier(error?["code"], redacting: key)
                $0.providerType = ModelDiagnostics.identifier(error?["type"], redacting: key)
            }
        }
    }

    func begin(
        configuration: ModelConfiguration, endpoint: URL, key: String, requestBytes: Int,
        messages: Int, tools: Int, exchanges: Int, maxOutputTokens: Int?, context: Context?
    ) -> Request {
        let request = Request(context: context ?? Context(runID: UUID().uuidString.lowercased()), diagnostics: self)
        request.emit("request.start") {
            $0.api = configuration.apiProtocol.rawValue
            $0.service = Self.identifier(endpoint.host, redacting: key)
            $0.model = Self.identifier(configuration.model, redacting: key)
            $0.requestBytes = requestBytes
            $0.maxOutputTokens = maxOutputTokens
            $0.messageCount = messages
            $0.toolCount = tools
            $0.exchangeCount = exchanges
        }
        return request
    }

    func run(_ name: String, context: Context, outcome: String? = nil) {
        record(Event(name: name, runID: context.runID, outcome: outcome))
    }

    func tool(
        _ name: String, context: Context, call: ModelToolCall, started: ContinuousClock.Instant,
        key: String, outcome: String? = nil
    ) {
        var event = Event(name: name, runID: context.runID)
        event.tool = Self.identifier(call.name, redacting: key)
        event.toolID = String(DocumentRevision.text(call.id).prefix(16))
        event.argumentBytes = call.arguments.utf8.count
        event.elapsedMS = Self.elapsed(since: started)
        event.outcome = Self.identifier(outcome, redacting: key)
        record(event)
    }

    static func outcome(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? URLError {
            return error.code == .cancelled ? "cancelled" : "network_\(error.code.rawValue)"
        }
        return AgentFailure(error).kind
    }

    static func toolOutcome(_ execution: AgentToolExecution) -> String {
        guard let object = try? ModelWireFormat.object(Data(execution.output.utf8)) else { return "completed" }
        return object["error"] as? String ?? object["status"] as? String ?? "completed"
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> Int {
        let value = start.duration(to: .now).components
        return max(0, Int(value.seconds) * 1000 + Int(value.attoseconds / 1_000_000_000_000_000))
    }

    /// Only bounded identifiers are accepted; URLs, prose and known credentials are excluded.
    private static func identifier(_ value: Any?, redacting key: String) -> String? {
        let text: String
        if let number = value as? NSNumber {
            text = number.stringValue
        } else if let value = value as? String {
            text = value
        } else {
            return nil
        }
        guard !text.isEmpty, text.utf8.count <= 256, !text.contains("://"),
            key.isEmpty || !text.contains(key)
        else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:/@+"))
        return text.unicodeScalars.allSatisfy(allowed.contains) ? text : nil
    }
}
