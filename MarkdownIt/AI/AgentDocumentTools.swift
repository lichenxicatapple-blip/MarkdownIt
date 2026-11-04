import CryptoKit
import Foundation

struct AgentTextEdit: Codable, Sendable, Equatable {
    let before: String
    let after: String
}

struct AgentDocumentChange: Codable, Sendable {
    let id: String
    let edits: [AgentTextEdit]
    let saved: Bool?
}

struct AgentToolExecution: Codable, Sendable {
    let output: String
    var change: AgentDocumentChange?
    var revision: String?
    var images: [ModelImage] = []
}

@MainActor
final class AgentDocumentTools {
    private weak var session: ReaderSession?
    struct UndoRecord: Codable, Sendable {
        let token: String
        let after: String
    }
    private var undoRecords: [String: UndoRecord] = [:]
    struct Recovery: Codable, Sendable {
        let undo: [String: UndoRecord]
        let receipts: [String: AgentToolExecution]
    }
    private var receipts: [String: AgentToolExecution] = [:]
    var checkpoint: (@MainActor () async -> Void)?
    func recovery() -> Recovery { Recovery(undo: undoRecords, receipts: receipts) }
    func restore(_ value: Recovery) {
        undoRecords = value.undo
        receipts = value.receipts
    }
    private var executing = false

    init(session: ReaderSession) { self.session = session }

    nonisolated static func revision(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static let definitions = [
        ModelTool(
            name: "read_document",
            description:
                "读取当前文档或已提供材料。documentID 为 null 时读取当前文件最新内容；否则只读取已提供的版本或引用 ID。characterOffset 是从 0 开始的完整 Unicode 字符位置，中文、组合字符和 emoji 不拆分，null 从头开始；query 可搜索文字，null 顺序读取。结果可能只有一段，按 nextCharacterOffset 继续；complete 为 true 才表示全文。无路径参数，不能访问其他文件。",
            parameters:
                #"{"type":"object","properties":{"documentID":{"type":["string","null"]},"characterOffset":{"type":["integer","null"],"minimum":0},"query":{"type":["string","null"]}},"required":["documentID","characterOffset","query"],"additionalProperties":false}"#
        ),
        ModelTool(
            name: "edit_document",
            description:
                "按用户明确的编辑要求修改当前文档。一次提交同一版本中所有互不重叠的修改。before 必须是唯一、逐字一致的原文，after 为完整替换文本。插入内容需保留原文锚点；仅空文档可用空 before。修改立即应用并尝试保存，以工具返回结果为准，无须另行请求应用。",
            parameters:
                #"{"type":"object","properties":{"revision":{"type":"string","description":"当前文档全文的 revision；内容变化后须重新读取。"},"edits":{"type":"array","minItems":1,"items":{"type":"object","properties":{"before":{"type":"string"},"after":{"type":"string"}},"required":["before","after"],"additionalProperties":false}}},"required":["revision","edits"],"additionalProperties":false}"#
        ),
    ]

    func reset() {
        undoRecords.removeAll()
        receipts.removeAll()
    }

    func execute(
        _ call: ModelToolCall, token: String, requestID: String? = nil, maxReadBytes: Int = 8192,
        onChange: @MainActor (AgentDocumentChange) async -> Void = { _ in }
    ) async -> AgentToolExecution {
        let receiptID = requestID.map { Self.revision(token + $0 + call.id + call.name + call.arguments) }
        if let receiptID, let receipt = receipts[receiptID] { return receipt }
        guard !executing else { return result(["error": "document_busy"]) }
        executing = true
        defer { executing = false }
        do {
            try Task.checkCancellation()
            guard let session, session.documentToken == token, session.document != nil,
                !session.isClosingDocument
            else { return result(["error": "document_closed"]) }
            let current = try currentText(session, token: token)
            switch call.name {
            case "read_document":
                let arguments = try ModelWireFormat.object(Data(call.arguments.utf8))
                if let id = arguments["documentID"] as? String, id != AgentContextSources.id(current) {
                    return result(["error": "unknown_document"])
                }
                return try AgentContextSources.read(current, arguments: arguments, maxBytes: maxReadBytes)
            case "edit_document":
                guard session.mode == "source" else {
                    return result(["error": "read_only", "message": "请切换到源码模式后再修改。"])
                }
                struct Arguments: Decodable {
                    let revision: String
                    let edits: [AgentTextEdit]
                }
                let object = try ModelWireFormat.object(Data(call.arguments.utf8))
                guard Set(object.keys) == ["revision", "edits"],
                    let edits = object["edits"] as? [[String: Any]],
                    edits.allSatisfy({ Set($0.keys) == ["before", "after"] })
                else { return result(["error": "invalid_arguments"]) }
                let args = try JSONDecoder().decode(Arguments.self, from: Data(call.arguments.utf8))
                guard args.revision == Self.revision(current) else {
                    return result(["error": "stale_document", "message": "文档已变化，请重新读取后再决定修改。"])
                }
                let planned = try Self.plan(args.edits, in: current)
                let next = planned.reduce(current) { text, edit in
                    (text as NSString).replacingCharacters(in: edit.range, with: edit.after)
                }
                guard next != current else {
                    return result(["status": "unchanged", "revision": Self.revision(current)])
                }
                let id = UUID().uuidString.lowercased()
                try Task.checkCancellation()
                guard replace(session, expected: current, next: next, id: id, token: token) else {
                    return result(["error": "stale_document", "message": "原文已变化，未执行这次修改。"])
                }
                undoRecords[id] = UndoRecord(token: token, after: next)
                var pending = result([
                    "status": "edited_save_pending", "revision": Self.revision(next),
                    "message": "内容已修改，保存结果未知；不要重复执行同一修改。",
                ])
                pending.change = AgentDocumentChange(id: id, edits: args.edits, saved: nil)
                if let receiptID { receipts[receiptID] = pending }
                await checkpoint?()
                await onChange(AgentDocumentChange(id: id, edits: args.edits, saved: nil))
                let saved = await save(session, token: token)
                var execution = result([
                    "status": saved ? "saved" : "edited_save_failed", "revision": Self.revision(next),
                    "message": saved ? "修改已写回当前文件。" : "内容已修改，保存失败；不得声称已保存，也不要重复执行同一修改。",
                ])
                execution.change = AgentDocumentChange(id: id, edits: args.edits, saved: saved)
                if let receiptID { receipts[receiptID] = execution }
                await checkpoint?()
                return execution
            default: return result(["error": "unknown_tool"])
            }
        } catch {
            if call.name == "read_document" { return AgentContextSources.invalidReadArguments }
            return result(["error": "invalid_edit", "message": "原文必须逐字匹配、唯一且互不重叠；未执行这次修改。"])
        }
    }

    func undo(_ id: String, token: String) async -> [String: String] {
        guard !executing else {
            return ["error": "busy", "message": String(localized: "The document is being saved. Try again shortly.")]
        }
        executing = true
        defer { executing = false }
        do {
            guard let session, let bridge = session.bridge, let record = undoRecords[id], record.token == token,
                session.documentToken == token, !session.isClosingDocument
            else { return ["error": "stale", "message": String(localized: "This edit can no longer be undone.")] }
            guard session.mode == "source" else {
                return ["error": "read_only", "message": String(localized: "Switch to source mode to undo this edit.")]
            }
            let current = try currentText(session, token: token)
            guard current == record.after else {
                return [
                    "error": "stale",
                    "message": String(localized: "The document has other changes. This edit cannot be undone."),
                ]
            }
            guard bridge.moveSourceHistory(forward: false, id: id) else {
                return [
                    "error": "stale", "message": String(localized: "Undo later changes before undoing this edit."),
                ]
            }
            let saved = await save(session, token: token)
            return ["status": "undone", "saved": saved ? "true" : "false"]
        } catch {
            return [
                "error": "stale", "message": String(localized: "The document has changed. This edit cannot be undone."),
            ]
        }
    }

    private func currentText(_ session: ReaderSession, token: String) throws -> String {
        guard session.documentToken == token, let bridge = session.bridge, let text = bridge.flushSource(),
            session.document != nil, !session.isClosingDocument
        else {
            throw ModelError.invalidResponse
        }
        return text
    }

    private func replace(_ session: ReaderSession, expected: String, next: String, id: String, token: String)
        -> Bool
    {
        guard session.documentToken == token, session.mode == "source", !session.isClosingDocument else { return false }
        return session.bridge?.applySourceEdit(before: expected, after: next, id: id) == true
    }

    private func save(_ session: ReaderSession, token: String) async -> Bool {
        let saved = await session.flushChanges()
        return saved && session.documentToken == token && session.document?.hasUnsavedChanges == false
    }

    private struct Replacement {
        let range: NSRange
        let after: String
    }

    private static func plan(_ edits: [AgentTextEdit], in text: String) throws -> [Replacement] {
        guard !edits.isEmpty else { throw ModelError.invalidResponse }
        let original = text as NSString
        let values = try edits.map { edit -> Replacement in
            if original.length == 0, edit.before.isEmpty, edits.count == 1 {
                return Replacement(range: NSRange(location: 0, length: 0), after: edit.after)
            }
            guard !edit.before.isEmpty else { throw ModelError.invalidResponse }
            let first = original.range(of: edit.before, options: .literal)
            guard first.location != NSNotFound else { throw ModelError.invalidResponse }
            let rest = NSRange(location: first.location + 1, length: original.length - first.location - 1)
            guard original.range(of: edit.before, options: .literal, range: rest).location == NSNotFound else {
                throw ModelError.invalidResponse
            }
            return Replacement(range: first, after: edit.after)
        }.sorted { $0.range.location > $1.range.location }
        for (later, earlier) in zip(values, values.dropFirst()) {
            guard NSMaxRange(earlier.range) <= later.range.location else { throw ModelError.invalidResponse }
        }
        return values
    }

    private func result(_ value: [String: Any]) -> AgentToolExecution {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys)) ?? Data("{}".utf8)
        return AgentToolExecution(
            output: String(decoding: data, as: UTF8.self), revision: session?.document.map { Self.revision($0.text) })
    }
}
