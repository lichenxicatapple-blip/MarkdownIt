import Foundation
import SwiftUI

struct BookmarkedLocation: Codable, Equatable, Sendable {
    let url: URL
    let bookmark: Data?

    nonisolated init(_ url: URL) {
        self.url = url
        bookmark = try? url.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    nonisolated func resolve() throws -> URL {
        let resolved: URL
        if let bookmark {
            var stale = false
            do {
                resolved = try URL(
                    resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutImplicitStartAccessing],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                // App-owned files already have access. A failed bookmark must not
                // prevent reopening an existing file inside the application container.
                guard Self.isAppOwned(url), FileManager.default.fileExists(atPath: url.path) else { throw error }
                resolved = url
            }
            // A successful open captures fresh bookmarks while access is active.
        } else {
            resolved = url
        }
        guard resolved.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        return resolved
    }

    nonisolated static func isAppOwned(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath()
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == container.path || path.hasPrefix(container.path + "/")
    }
}

struct RecentDocument: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let file: BookmarkedLocation
    let identity: URL
    var folders: [BookmarkedLocation]

    var name: String { file.url.lastPathComponent }
    var parent: String { file.url.deletingLastPathComponent().lastPathComponent }
}

struct RecentDocumentLocation: Sendable {
    let file: URL
    let folders: [URL]
}

@MainActor
final class RecentDocumentsStore: ObservableObject {
    static let storageKey = "recentDocuments.v1"
    private static let maximumCount = 10
    @Published private(set) var documents: [RecentDocument]
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored =
            defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([RecentDocument].self, from: $0) } ?? []
        var seen: Set<URL> = []
        documents = Array(
            stored.filter { $0.file.url.isFileURL && seen.insert($0.identity).inserted }.prefix(Self.maximumCount))
    }

    nonisolated static func prepare(_ url: URL, folders: [URL], replacing id: UUID? = nil) async -> RecentDocument {
        await Task.detached(priority: .userInitiated) {
            RecentDocument(
                id: id ?? UUID(), file: BookmarkedLocation(url),
                identity: url.resolvingSymlinksInPath().standardizedFileURL,
                folders: folders.map { BookmarkedLocation($0) })
        }.value
    }

    func record(_ captured: RecentDocument) {
        var next = captured
        if let previous = documents.first(where: { $0.id == next.id || $0.identity == next.identity }) {
            next = RecentDocument(
                id: previous.id, file: next.file, identity: next.identity,
                folders: merging(previous.folders, with: next.folders))
        }
        documents = Array(
            ([next] + documents.filter { $0.id != next.id && $0.identity != next.identity }).prefix(Self.maximumCount))
        persist()
    }

    func rememberFolders(_ urls: [URL], for document: URL) async {
        guard !urls.isEmpty else { return }
        let folders = await Task.detached(priority: .userInitiated) { urls.map { BookmarkedLocation($0) } }.value
        guard
            let index = documents.firstIndex(where: { $0.file.url.standardizedFileURL == document.standardizedFileURL })
        else { return }
        documents[index].folders = merging(documents[index].folders, with: folders)
        persist()
    }

    func resolve(_ document: RecentDocument) async throws -> RecentDocumentLocation {
        try await Task.detached(priority: .userInitiated) {
            RecentDocumentLocation(
                file: try document.file.resolve(), folders: document.folders.compactMap { try? $0.resolve() })
        }.value
    }

    /// Reuse directory grants without replacing the fresh file URL supplied by Files or the picker.
    func folders(for url: URL) async -> [URL] {
        let stored = documents
        return await Task.detached(priority: .userInitiated) {
            let identity = url.resolvingSymlinksInPath().standardizedFileURL
            guard let document = stored.first(where: { $0.identity == identity }) else { return [] }
            return document.folders.compactMap { try? $0.resolve() }
        }.value
    }

    private func merging(_ existing: [BookmarkedLocation], with incoming: [BookmarkedLocation]) -> [BookmarkedLocation]
    {
        var result = existing
        for folder in incoming {
            result.removeAll { $0.url.standardizedFileURL == folder.url.standardizedFileURL }
            result.append(folder)
        }
        return result
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(documents) { defaults.set(data, forKey: Self.storageKey) }
    }
}
