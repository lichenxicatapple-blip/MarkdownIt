import CoreFoundation
import Foundation

/// Immutable request materials. IDs survive history compaction; no paths can be opened by this tool.
struct AgentContextSources: Codable, Sendable {
    static let invalidReadArguments = AgentToolExecution(
        output:
            #"{"error":"invalid_arguments","message":"Use documentID, characterOffset and query only. characterOffset is a zero-based Unicode character position, from 0 through totalCharacters, or null to start at the beginning. Use nextCharacterOffset to continue or query to search. query must be null or nonempty text."}"#
    )

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

    func read(_ call: ModelToolCall, maxBytes: Int) -> AgentToolExecution? {
        do {
            let args = try ModelWireFormat.object(Data(call.arguments.utf8))
            guard let id = args["documentID"] as? String else { return nil }
            guard let source = sources[id] else { return nil }
            return try Self.read(source.content, arguments: args, maxBytes: maxBytes, id: id)
        } catch {
            // A rejected tool argument is a tool result, not an unreadable model
            // response. Journal it so restored requests can advance past the call.
            return Self.invalidReadArguments
        }
    }

    static func read(
        _ text: String, arguments: [String: Any], maxBytes: Int, id: String? = nil
    ) throws -> AgentToolExecution {
        guard Set(arguments.keys).isSubset(of: ["documentID", "characterOffset", "query"]) else {
            throw ModelError.invalidResponse
        }
        if let id = arguments["documentID"], !(id is NSNull), !(id is String) { throw ModelError.invalidResponse }
        let totalCharacters = text.count
        let offset: Int
        if let value = arguments["characterOffset"], !(value is NSNull) {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                number.doubleValue >= 0, number.doubleValue <= Double(totalCharacters)
            else { throw ModelError.invalidResponse }
            offset = number.intValue
        } else {
            offset = 0
        }
        var start = offset
        var startIndex = text.index(text.startIndex, offsetBy: start)
        if let value = arguments["query"], !(value is NSNull) {
            guard let query = value as? String, !query.isEmpty else { throw ModelError.invalidResponse }
            guard let match = text.range(of: query, options: [.caseInsensitive], range: startIndex..<text.endIndex)
            else {
                return AgentToolExecution(output: #"{"status":"not_found"}"#)
            }
            start += text.distance(from: startIndex, to: match.lowerBound)
            startIndex = match.lowerBound
        }
        var end = start
        var endIndex = startIndex
        var bytes = 0
        while endIndex < text.endIndex {
            let next = text.index(after: endIndex)
            let size = text[endIndex..<next].utf8.count
            guard bytes + size <= max(4, maxBytes) else { break }
            bytes += size
            endIndex = next
            end += 1
        }
        guard end > start || startIndex == text.endIndex else {
            return AgentToolExecution(
                output:
                    #"{"error":"character_too_large","message":"This character exceeds the reading limit and cannot be returned intact."}"#
            )
        }
        var result: [String: Any] = [
            "documentID": id ?? Self.id(text), "revision": AgentDocumentTools.revision(text),
            "content": String(text[startIndex..<endIndex]),
            "characterOffset": start, "totalCharacters": totalCharacters,
            "complete": start == 0 && end == totalCharacters,
            "nextCharacterOffset": end < totalCharacters ? end as Any : NSNull(),
        ]
        if start > 0 { result["precedingContentOmitted"] = true }
        let data = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
        return AgentToolExecution(
            output: String(decoding: data, as: UTF8.self), revision: AgentDocumentTools.revision(text))
    }
}
