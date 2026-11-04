import Foundation

/// UI quotes identify the focus; complete document snapshots supply the reading background.
enum AgentContextBuilder {
    static func systemMessage(
        for snapshot: AgentSnapshot,
        appLanguage: String = Bundle.main.preferredLocalizations.first ?? "en"
    ) -> ChatMessage {
        ChatMessage(
            role: "system",
            content: AgentPrompt.instructions(
                mode: snapshot.document?.mode ?? snapshot.attachment?.mode ?? "preview", appLanguage: appLanguage))
    }

    private struct Document: Encodable {
        let id: String
        let documentName: String?
        let format = "markdown"
        let content: String?
        let revision: String
        let availability: String?
    }
    private struct Image: Encodable {
        let id: String
        let source: String
        let alt: String
        let documentID: String?
    }
    private struct Background: Encodable {
        let currentDocumentID: String?
        let documents: [Document]
        let images: [Image]
        let currentImageIDs: [String]
    }
    private struct Reference: Encodable {
        let scope: String
        let format: String
        let content: String?
        let documentID: String?
        let imageIDs: [String]?
        let contentID: String?
    }
    private struct UserTurn: Encodable {
        let request: String
        let documentID: String?
        let reference: Reference?
        let background: Background?
    }
    private struct AssistantTurn: Encodable {
        let answer: String
        let status: String
        let sourceChanges: [AgentSourceChange]
    }
    private struct Documents {
        var values: [Document] = []
        private var ids: [String: String] = [:]
        var inlineLimit: Int?

        mutating func register(_ markdown: String?, name: String?) -> String? {
            guard let markdown else { return nil }
            if let id = ids[markdown] { return id }
            let id = AgentContextSources.id(markdown)
            let inline = inlineLimit.map { markdown.utf8.count <= $0 } ?? true
            ids[markdown] = id
            values.append(
                Document(
                    id: id, documentName: name.map { URL(fileURLWithPath: $0).lastPathComponent },
                    content: inline ? markdown : nil, revision: AgentDocumentTools.revision(markdown),
                    availability: inline ? nil : "read_document"))
            return id
        }
    }

    static func build(
        _ snapshot: AgentSnapshot, intent: String,
        appLanguage: String = Bundle.main.preferredLocalizations.first ?? "en",
        inlineLimit: Int? = nil, quoteLimit: Int? = nil, summary: String? = nil
    ) throws -> [ChatMessage] {
        let history = snapshot.history
        guard intent == "question",
            !snapshot.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            history.last?.role == "user", history.last?.markdown == snapshot.question,
            history.last?.attachment == snapshot.attachment,
            history.last?.document == snapshot.document,
            history.allSatisfy({ ["user", "assistant"].contains($0.role) })
        else { throw ModelError.invalidResponse }
        if let attachment = snapshot.attachment, attachment.mode == "source", attachment.scope != "document" {
            guard let start = attachment.start, let end = attachment.end, start >= 0,
                end > start, attachment.text.utf16.count == end - start
            else { throw ModelError.invalidResponse }
        }
        var documents = Documents(inlineLimit: inlineLimit)
        var documentIDs: [String?] = []
        var referenceIDs: [String?] = []
        for turn in history {
            let documentID = documents.register(turn.document?.markdown, name: turn.document?.documentName)
            documentIDs.append(documentID)
            let reference = turn.attachment
            let quoteDocument = reference?.scope == "document" ? reference?.markdown : reference?.documentMarkdown
            referenceIDs.append(documents.register(quoteDocument, name: reference?.documentName) ?? documentID)
        }
        let current =
            snapshot.document ?? history.last?.document
            ?? (snapshot.attachment?.scope == "document" ? snapshot.attachment : nil)
        let currentID = documents.register(current?.markdown, name: current?.documentName)
        var imageInventory: [Image] = []
        var imageIDs = Set<String>()
        for (index, turn) in history.enumerated() {
            for (attachment, documentID) in [
                (turn.document, documentIDs[index]), (turn.attachment, referenceIDs[index]),
            ] {
                for image in attachment?.images ?? [] where imageIDs.insert(image.id).inserted {
                    imageInventory.append(
                        Image(id: image.id, source: image.source, alt: image.alt, documentID: documentID))
                }
            }
        }
        let background =
            documents.values.isEmpty
            ? nil
            : Background(
                currentDocumentID: currentID, documents: documents.values, images: imageInventory,
                currentImageIDs: (current?.images ?? []).map(\.id))
        let memory = try summary.map { ChatMessage(role: "user", content: try encode(["conversationSummary": $0])) }
        return [systemMessage(for: snapshot, appLanguage: appLanguage)] + (memory.map { [$0] } ?? [])
            + (try history.enumerated().map { index, turn in
                if turn.role == "assistant" {
                    return try ChatMessage(
                        role: turn.role,
                        content: encode(
                            AssistantTurn(
                                answer: turn.markdown, status: turn.status ?? "complete",
                                sourceChanges: turn.changes ?? [])))
                }
                let reference = turn.attachment.map { value in
                    let sourceEdit = value.mode == "source"
                    let content = sourceEdit ? value.text : value.markdown
                    let inline = (quoteLimit ?? inlineLimit).map { content.utf8.count <= $0 } ?? true
                    return Reference(
                        scope: value.scope == "document" ? "document" : "selection",
                        format: sourceEdit ? "markdown-source" : "markdown",
                        content: value.scope == "document" || !inline ? nil : content,
                        documentID: referenceIDs[index],
                        imageIDs: value.images?.isEmpty == false ? value.images?.map(\.id) : nil,
                        contentID: value.scope != "document" && !inline ? AgentContextSources.id(content) : nil)
                }
                return try ChatMessage(
                    role: turn.role,
                    content: encode(
                        UserTurn(
                            request: turn.markdown,
                            documentID: documentIDs[index], reference: reference,
                            background: index == history.count - 1 ? background : nil)))
            })
    }

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
