import Foundation

/// Conversation ownership is independent of the lifetime of an open reader.
struct AgentConversation: Codable, Sendable {
    let contextID: String
    let web: Data
    let images: AgentImages.Recovery
    let tools: AgentDocumentTools.Recovery
    let transport: AgentModelTransport.Recovery?
    var composer: NativeComposerHost.Recovery? = nil
}

/// One protected record per normalized document path. A new owner retires late writes.
actor AgentConversationStore {
    nonisolated let directory: URL
    private var owners: [String: (id: UUID, sequence: UInt64)] = [:]

    private struct Record: Codable {
        var version = 1
        let path: String
        let conversation: AgentConversation
    }

    nonisolated static func applicationDirectory(testing: Bool = false) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent(
            testing ? "TestConversations" : "Conversations", isDirectory: true)
    }

    init(directory: URL = AgentConversationStore.applicationDirectory()) { self.directory = directory }

    nonisolated static func path(for url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let documents = URL.documentsDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        // An App update may relocate its container; the document's logical path stays the same.
        return path.hasPrefix(documents) ? "app-documents:/" + path.dropFirst(documents.count) : path
    }

    private func file(_ path: String) -> URL {
        directory.appendingPathComponent(DocumentRevision.text(path)).appendingPathExtension("lzfse")
    }

    func load(path: String, owner: UUID) throws -> AgentConversation? {
        let file = file(path)
        var conversation: AgentConversation?
        if FileManager.default.fileExists(atPath: file.path) {
            let compressed = try Data(contentsOf: file) as NSData
            let record = try PropertyListDecoder().decode(
                Record.self, from: compressed.decompressed(using: .lzfse) as Data)
            guard record.version == 1, record.path == path else { throw CocoaError(.coderReadCorrupt) }
            conversation = record.conversation
        }
        owners[path] = (owner, 0)
        return conversation
    }

    func save(_ conversation: AgentConversation, path: String, owner: UUID, sequence: UInt64) throws {
        guard let current = owners[path], current.id == owner, sequence > current.sequence else { return }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Record(path: path, conversation: conversation)) as NSData
        try (data.compressed(using: .lzfse) as Data).write(
            to: file(path), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        owners[path] = (owner, sequence)
    }

    func reset() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        owners.removeAll()
    }
}
