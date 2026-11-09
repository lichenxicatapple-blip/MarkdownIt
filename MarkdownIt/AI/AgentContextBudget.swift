import Foundation

/// Token estimates are deliberately conservative and can be calibrated from provider usage.
/// Only declared limits constrain requests; unknown capacities never create a synthetic window.
struct AgentContextBudget: Sendable {
    let capabilities: ModelCapabilities
    let limit: Int?
    let tokenScale: Double

    init(capabilities: ModelCapabilities = ModelCapabilities(), tokenScale: Double = 1) {
        self.capabilities = capabilities
        self.tokenScale = tokenScale.isFinite ? max(1, tokenScale) : 1
        // Start compaction before a known window is full. This scheduling margin
        // is independent of the output cap fitted to each actual request below.
        let totalInput = capabilities.contextWindow.map { max(1, $0 - $0 / 10) }
        limit = [totalInput, capabilities.maxInputTokens.map { max(1, $0 - $0 / 20) }]
            .compactMap { $0 }.min()
    }

    var target: Int? { limit.map { max(1, $0 - $0 / 4) } }
    var summaryTokens: Int? { limit.map { max(1, $0 / 8) } }

    // A page size for tool I/O, not a model window or a generation constraint.
    var readByteLimit: Int { limit.map { max(4, Int(Double($0 / 4) / tokenScale)) } ?? 65_536 }

    func fits(_ cost: Int, target: Bool = false) -> Bool {
        (target ? self.target : limit).map { cost <= $0 } ?? true
    }

    func outputLimit(inputCost: Int) -> Int? {
        guard let output = capabilities.maxOutputTokens else { return nil }
        guard let window = capabilities.contextWindow else { return output }
        return min(output, max(1, window - min(window, inputCost) - window / 20))
    }

    func cost(_ messages: [ChatMessage], exchanges: [ModelToolExchange] = [], tools: [ModelTool] = []) -> Int {
        let estimate = ceil(Double(Self.estimate(messages, exchanges: exchanges, tools: tools)) * tokenScale)
        return estimate >= Double(Int.max) ? Int.max : Int(estimate)
    }

    static func estimate(
        _ messages: [ChatMessage], exchanges: [ModelToolExchange] = [], tools: [ModelTool] = []
    ) -> Int {
        messages.reduce(0) { $0 + textTokens($1.content) + 16 + $1.images.count * 4096 }
            + tools.reduce(0) {
                $0 + textTokens($1.name + $1.description + String(decoding: $1.parameters, as: UTF8.self)) + 32
            }
            + exchanges.reduce(0) { count, exchange in
                // The wire envelope already contains answer text and arguments.
                // Count its one protocol representation, without counting text twice.
                let response = exchange.turn.responseItems.reduce(0) {
                    $0 + textTokens(String(decoding: $1, as: UTF8.self))
                }
                let chat = exchange.turn.chatAssistant.map { textTokens(String(decoding: $0, as: UTF8.self)) } ?? 0
                let plain =
                    textTokens(exchange.turn.text)
                    + exchange.turn.calls.reduce(0) { $0 + textTokens($1.name + $1.arguments) + 16 }
                return count + max(response, chat, plain)
                    + exchange.outputs.reduce(0) {
                        $0 + textTokens($1.content) + $1.images.count * 4096 + 16
                    }
            }
    }

    static func textTokens(_ text: String) -> Int {
        var tokens = 0
        var asciiRun = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 48...57, 65...90, 97...122, 9, 10, 13, 32:
                asciiRun += 1
            default:
                tokens += (asciiRun + 2) / 3
                asciiRun = 0
                // CJK, combining marks and emoji must not be estimated at one
                // token per four characters. Punctuation is counted separately.
                tokens += scalar.isASCII ? 1 : (scalar.utf8.count + 1) / 2
            }
        }
        return tokens + (asciiRun + 2) / 3
    }
}
