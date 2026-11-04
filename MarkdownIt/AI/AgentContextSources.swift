import CoreFoundation
import Foundation

/// Immutable request materials. IDs survive history compaction; no paths can be opened by this tool.
struct AgentContextSources: Codable, Sendable {
    struct Source: Codable, Sendable {
        let id: String
        let content: String
    }

    private(set) var sources: [String: Source] = [:]

    init(_ snapshot: AgentSnapshot) {
        for attachment in snapshot.history.flatMap({ [$0.document, $0.attachment].compactMap { $0 } })
            + [snapshot.document, snapshot.attachment].compactMap({ $0 })
        {
            register(attachment.markdown)
            if let original = attachment.documentMarkdown { register(original) }
            if attachment.scope != "document" {
                register(attachment.mode == "source" ? attachment.text : attachment.markdown)
            }
        }
    }

    static func id(_ content: String) -> String { "document-" + AgentDocumentTools.revision(content) }

    private mutating func register(_ content: String) {
        let id = Self.id(content)
        sources[id] = Source(id: id, content: content)
    }

    func read(_ call: ModelToolCall, maxBytes: Int) throws -> AgentToolExecution? {
        let args = try ModelWireFormat.object(Data(call.arguments.utf8))
        guard let id = args["documentID"] as? String else { return nil }
        guard let source = sources[id] else { return nil }
        return try Self.read(source.content, arguments: args, maxBytes: maxBytes, id: id)
    }

    static func read(
        _ text: String, arguments: [String: Any], maxBytes: Int, id: String? = nil
    ) throws -> AgentToolExecution {
        guard Set(arguments.keys).isSubset(of: ["documentID", "offset", "query"]) else {
            throw ModelError.invalidResponse
        }
        if let id = arguments["documentID"], !(id is NSNull), !(id is String) { throw ModelError.invalidResponse }
        let bytes = Array(text.utf8)
        let offset: Int
        if let value = arguments["offset"], !(value is NSNull) {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                number.doubleValue >= 0, number.doubleValue <= Double(bytes.count)
            else { throw ModelError.invalidResponse }
            offset = number.intValue
        } else {
            offset = 0
        }
        guard offset == bytes.count || bytes[offset] & 0xC0 != 0x80 else { throw ModelError.invalidResponse }
        var start = offset
        if let value = arguments["query"], !(value is NSNull) {
            guard let query = value as? String, !query.isEmpty else { throw ModelError.invalidResponse }
            let suffix = String(decoding: bytes[offset...], as: UTF8.self)
            guard let match = suffix.range(of: query, options: [.caseInsensitive]) else {
                return AgentToolExecution(output: #"{"status":"not_found"}"#)
            }
            start += suffix[..<match.lowerBound].utf8.count
        }
        var end = min(bytes.count, start + max(4, maxBytes))
        while end < bytes.count && bytes[end] & 0xC0 == 0x80 { end -= 1 }
        var result: [String: Any] = [
            "documentID": id ?? Self.id(text), "revision": AgentDocumentTools.revision(text),
            "content": String(decoding: bytes[start..<end], as: UTF8.self),
            "offset": start, "totalBytes": bytes.count, "complete": start == 0 && end == bytes.count,
            "nextOffset": end < bytes.count ? end as Any : NSNull(),
        ]
        if start > 0 { result["precedingContentOmitted"] = true }
        let data = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
        return AgentToolExecution(
            output: String(decoding: data, as: UTF8.self), revision: AgentDocumentTools.revision(text))
    }
}
