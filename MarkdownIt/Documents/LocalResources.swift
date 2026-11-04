import Foundation
import UniformTypeIdentifiers
import WebKit

struct ResourceAccess: Sendable {
    var documentURL: URL
    var roots: [URL]
    var token: String

    func resolve(_ source: String) throws -> URL {
        let candidate = try resourceURL(source)
        guard contains(candidate) else { throw CocoaError(.fileReadNoPermission) }
        return candidate
    }

    func rootsRequired(for sources: [String]) -> [URL] {
        let files = [canonicalURL(documentURL)] + sources.compactMap { try? resourceURL($0) }
        return roots.filter { root in files.contains { Self.contains($0, in: canonicalURL(root)) } }
    }

    func directoryRequiringAccess(for sources: [String]) -> URL? {
        directoriesRequiringAccess(for: sources).first
    }

    /// Request actual resource folders, never an inferred common ancestor.
    /// A folder that directly contains a reference can also cover its children.
    func directoriesRequiringAccess(for sources: [String]) -> [URL] {
        var directories: [URL] = []
        for source in sources {
            guard let file = try? resourceURL(source), !contains(file) else { continue }
            let directory = file.deletingLastPathComponent()
            guard directory.path != "/" else { continue }
            if directories.contains(where: { Self.contains(directory, in: $0) }) { continue }
            let index = directories.firstIndex { Self.contains($0, in: directory) } ?? directories.count
            directories.removeAll { Self.contains($0, in: directory) }
            directories.insert(directory, at: min(index, directories.count))
        }
        return directories
    }

    func directoryContaining(_ source: String) -> URL? {
        guard let file = try? resourceURL(source) else { return nil }
        let directory = file.deletingLastPathComponent()
        return directory.path == "/" ? nil : directory
    }

    func containsDirectory(_ directory: URL) -> Bool { contains(canonicalURL(directory)) }

    private func resourceURL(_ source: String) throws -> URL {
        guard !source.contains("\0"), let components = URLComponents(string: source) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        if let scheme = components.scheme, scheme.lowercased() != "file" {
            throw CocoaError(.fileReadNoPermission)
        }
        let path = components.path
        guard !path.isEmpty, !path.contains("\0") else { throw CocoaError(.fileReadInvalidFileName) }
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = documentURL.deletingLastPathComponent().appendingPathComponent(path)
        }
        return canonicalURL(url)
    }

    private func contains(_ candidate: URL) -> Bool {
        let file = canonicalURL(documentURL)
        return candidate == file || roots.contains { Self.contains(candidate, in: canonicalURL($0)) }
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        candidate.path == root.path
            || candidate.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    private func canonicalURL(_ url: URL) -> URL {
        // Resolve existing parents too: Foundation may leave the entire path
        // unchanged when its final component does not exist yet.
        url.standardizedFileURL.pathComponents.dropFirst().reduce(URL(fileURLWithPath: "/", isDirectory: true)) {
            $0.appendingPathComponent($1).resolvingSymlinksInPath()
        }
    }
}

@MainActor
final class LocalResourceHandler: NSObject, WKURLSchemeHandler {
    var onPermissionDenied: ((String, String) -> Void)?
    private var access: ResourceAccess?
    private var reportedDenial: String?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func configure(_ value: ResourceAccess) {
        access = value
        reportedDenial = nil
    }

    func clear() {
        access = nil
        reportedDenial = nil
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        var resourcePath: String?
        do {
            guard let url = urlSchemeTask.request.url,
                let access, url.host == access.token,
                let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {
                    $0.name == "path"
                })?.value
            else {
                throw CocoaError(.fileReadNoPermission)
            }
            resourcePath = source
            let file = try access.resolve(source)
            let id = ObjectIdentifier(urlSchemeTask)
            tasks[id] = Task { [weak self] in
                guard !Task.isCancelled else { return }
                do {
                    let data = try await Task.detached(priority: .userInitiated) { try Self.readCoordinated(file) }
                        .value
                    guard let self, self.tasks.removeValue(forKey: id) != nil, !Task.isCancelled else { return }
                    let type =
                        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    urlSchemeTask.didReceive(
                        URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                } catch {
                    guard let self, self.tasks.removeValue(forKey: id) != nil, !Task.isCancelled else { return }
                    self.reportPermission(error, token: url.host, source: source)
                    urlSchemeTask.didFailWithError(error)
                }
            }
        } catch {
            reportPermission(error, token: urlSchemeTask.request.url?.host, source: resourcePath)
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    private func reportPermission(_ error: Error, token: String?, source: String?) {
        guard let token, let source, token == access?.token, reportedDenial != token,
            (error as? CocoaError)?.code == .fileReadNoPermission
        else { return }
        reportedDenial = token
        onPermissionDenied?(token, source)
    }

    nonisolated static func readCoordinated(_ file: URL, options: Data.ReadingOptions = .mappedIfSafe) throws -> Data {
        var error: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: file, options: .withoutChanges, error: &error) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL, options: options) }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}
