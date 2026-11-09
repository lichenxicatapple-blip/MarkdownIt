import Foundation

/// Each normalized file path owns one protected, atomically replaced record.
/// Owners and monotonically increasing revisions reject writes from a retired reader.
actor ReadingAnnotationStore {
    let directory: URL
    private var owners: [String: (id: UUID, revision: UInt64)] = [:]

    private struct FileRecord: Codable {
        var version = 1
        let path: String
        let annotations: ReadingAnnotations
    }

    nonisolated static func applicationDirectory(testing: Bool = false) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent(
            testing ? "TestAnnotations" : "Annotations", isDirectory: true)
    }

    init(directory: URL = ReadingAnnotationStore.applicationDirectory()) {
        self.directory = directory
    }

    nonisolated static func path(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func file(for path: String) -> URL {
        let digest = DocumentRevision.text(path)
        return directory.appendingPathComponent(digest).appendingPathExtension("plist")
    }

    func load(path: String, owner: UUID) throws -> ReadingAnnotations {
        let file = file(for: path)
        var annotations = ReadingAnnotations()
        if FileManager.default.fileExists(atPath: file.path) {
            let record = try PropertyListDecoder().decode(FileRecord.self, from: Data(contentsOf: file))
            guard record.version == 1, record.path == path else { throw CocoaError(.fileReadCorruptFile) }
            try record.annotations.validate()
            annotations = record.annotations
        }
        owners[path] = (owner, 0)
        return annotations
    }

    func save(_ annotations: ReadingAnnotations, path: String, owner: UUID, revision: UInt64) throws {
        guard let current = owners[path], current.id == owner, revision >= current.revision else { return }
        try annotations.validate()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(FileRecord(path: path, annotations: annotations))
        try data.write(to: file(for: path), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        owners[path] = (owner, revision)
    }
}
