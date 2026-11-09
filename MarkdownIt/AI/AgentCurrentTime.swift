import Foundation

enum AgentCurrentTime {
    static let definition = ModelTool(
        name: "get_current_time",
        description: "获取当前日期、时间及时区。返回 ISO 8601 时间及 IANA 时区名称，用于理解今天、现在等相对时间。",
        parameters: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#)

    static func execute(
        _ call: ModelToolCall, now: Date = Date(), timeZone: TimeZone = .current
    ) -> AgentToolExecution {
        guard call.name == definition.name,
            let arguments = try? ModelWireFormat.object(Data(call.arguments.utf8)), arguments.isEmpty
        else {
            return AgentToolExecution(
                output:
                    #"{"error":"invalid_arguments","message":"get_current_time takes an empty object with no parameters."}"#
            )
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        let payload = ["currentTime": formatter.string(from: now), "timeZone": timeZone.identifier]
        guard let data = try? JSONEncoder().encode(payload) else {
            return AgentToolExecution(output: #"{"error":"time_unavailable"}"#)
        }
        return AgentToolExecution(output: String(decoding: data, as: UTF8.self))
    }
}
