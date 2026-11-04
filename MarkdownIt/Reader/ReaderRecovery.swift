import Foundation

/// A checkpoint of the open document, not a second document or editing buffer.
struct ReaderRecovery: Codable, Sendable {
    var version = 1
    let token: String
    let sequence: UInt64
    let location: RecentDocument
    let savedRevision: String
    let editor: SourceEditor.Recovery
    let composer: NativeComposerHost.Recovery?
    let web: Data?
    let images: AgentImages.Recovery
    let tools: AgentDocumentTools.Recovery
    let transport: AgentModelTransport.Recovery?
}

/// Serial, atomic replacement keeps the previous checkpoint intact on write failure.
/// Generation and sequence checks reject saves queued before a close or document switch.
actor ReaderRecoveryStore {
    nonisolated let directory: URL
    private var token: String?
    private var sequence: UInt64 = 0
    private var retired = Set<String>()
    private var locations: [String: UUID] = [:]

    init(directory: URL) { self.directory = directory }

    static func applicationDirectory(testing: Bool = false) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent(
            testing ? "TestRecovery" : "ReaderRecovery", isDirectory: true)
    }

    private struct Active: Codable { let id: UUID }
    private var activeFile: URL { directory.appendingPathComponent("active.plist") }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".lzfse") }

    private func read(_ id: UUID) throws -> ReaderRecovery? {
        let file = file(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let compressed = try Data(contentsOf: file) as NSData
        let record = try PropertyListDecoder().decode(
            ReaderRecovery.self, from: compressed.decompressed(using: .lzfse) as Data)
        guard record.version == 1, record.location.id == id else { throw CocoaError(.coderReadCorrupt) }
        locations[record.token] = id
        return record
    }

    func load() throws -> ReaderRecovery? {
        guard FileManager.default.fileExists(atPath: activeFile.path) else { return nil }
        let id = try PropertyListDecoder().decode(Active.self, from: Data(contentsOf: activeFile)).id
        guard let record = try read(id) else { throw CocoaError(.fileReadNoSuchFile) }
        token = record.token
        sequence = record.sequence
        return record
    }

    /// An inaccessible document's draft survives opening a different file.
    func load(location: RecentDocument) throws -> ReaderRecovery? { try read(location.id) }

    func save(_ record: ReaderRecovery) throws {
        guard !retired.contains(record.token), token != record.token || record.sequence > sequence else { return }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let compressed = try (encoder.encode(record) as NSData).compressed(using: .lzfse)
        try (compressed as Data).write(
            to: file(record.location.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try encoder.encode(Active(id: record.location.id)).write(
            to: activeFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        locations[record.token] = record.location.id
        token = record.token
        sequence = record.sequence
    }

    func remove(token: String) throws {
        retired.insert(token)
        if self.token == token, FileManager.default.fileExists(atPath: activeFile.path) {
            try FileManager.default.removeItem(at: activeFile)
        }
        if let id = locations.removeValue(forKey: token), FileManager.default.fileExists(atPath: file(id).path) {
            try FileManager.default.removeItem(at: file(id))
        }
        guard self.token == token else { return }
        self.token = nil
        sequence = 0
    }

    func reset() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        token = nil
        sequence = 0
        retired.removeAll()
        locations.removeAll()
    }
}
