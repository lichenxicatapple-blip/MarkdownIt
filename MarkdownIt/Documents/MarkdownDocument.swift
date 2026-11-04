import CryptoKit
import Foundation
import OSLog
import Synchronization
import UIKit

final class MarkdownDocument: UIDocument {
    static let supportedFilenameExtensions = ["md", "markdown", "mdown", "mkd"]

    var text = ""
    private let savedRevision = Mutex("")
    var persistedRevision: String { savedRevision.withLock { $0 } }

    private static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private var encoding = String.Encoding.utf8
    private var byteOrderMark = Data()
    private var lineEnding = "\n"
    private let operations = DocumentOperations()
    #if DEBUG
        private let simulatedWriteFailures = Mutex(0)

        func failNextWritesForTesting(_ count: Int) {
            simulatedWriteFailures.withLock { $0 = count }
        }
    #endif

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let data = contents as? Data else { throw CocoaError(.fileReadCorruptFile) }
        savedRevision.withLock { $0 = Self.revision(data) }
        let value: String
        byteOrderMark = Data()
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let decoded = String(data: data.dropFirst(3), encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            value = decoded
            byteOrderMark = Data([0xEF, 0xBB, 0xBF])
            encoding = .utf8
        } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            encoding = data.starts(with: [0xFF, 0xFE]) ? .utf16LittleEndian : .utf16BigEndian
            guard let decoded = String(data: data.dropFirst(2), encoding: encoding) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            value = decoded
            byteOrderMark = data.prefix(2)
        } else if let decoded = String(data: data, encoding: .utf8) {
            value = decoded
            encoding = .utf8
        } else {
            let gb = String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            guard let decoded = String(data: data, encoding: gb) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            value = decoded
            encoding = gb
        }
        // Editors use LF internally; preserve the file's first newline convention
        // on save. Merely opening or switching modes must not dirty a CRLF file.
        lineEnding = value.range(of: "\r\n|\r|\n", options: .regularExpression).map { String(value[$0]) } ?? "\n"
        text = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    override func contents(forType typeName: String) throws -> Any {
        #if DEBUG
            let fail = simulatedWriteFailures.withLock { remaining in
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
            if fail { throw CocoaError(.fileWriteNoPermission) }
        #endif
        let content = lineEnding == "\n" ? text : text.replacingOccurrences(of: "\n", with: lineEnding)
        guard let data = content.data(using: encoding, allowLossyConversion: false) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return byteOrderMark + data
    }

    override func writeContents(
        _ contents: Any, andAttributes additionalFileAttributes: [AnyHashable: Any]?,
        safelyTo url: URL, for saveOperation: UIDocument.SaveOperation
    ) throws {
        try super.writeContents(contents, andAttributes: additionalFileAttributes, safelyTo: url, for: saveOperation)
        if let data = contents as? Data { savedRevision.withLock { $0 = Self.revision(data) } }
    }

    @MainActor func openForReading() async -> Bool {
        await performOperation { open(completionHandler: $0) }
    }

    @MainActor func closeSavingChanges() async -> Bool {
        // Resolve encoding and write failures while the document is still open.
        // Begin UIDocument's closing lifecycle only after saving succeeds.
        if hasUnsavedChanges, !(await persist()) { return false }
        return await performOperation { close(completionHandler: $0) }
    }

    @MainActor func persist() async -> Bool {
        await performOperation { autosave(completionHandler: $0) }
    }

    @MainActor
    private func performOperation(_ start: (@escaping @Sendable (Bool) -> Void) -> Void) async -> Bool {
        let id = UUID()
        let operations = operations
        return await withCheckedContinuation { continuation in
            operations.register(continuation, id: id)
            start { operations.complete(id: id, success: $0) }
        }
    }

    override func handleError(_ error: Error, userInteractionPermitted: Bool) {
        let value = error as NSError
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "MarkdownIt", category: "Documents")
            .error("Document IO failed: \(value.domain, privacy: .public) (\(value.code, privacy: .public))")
        super.handleError(error, userInteractionPermitted: userInteractionPermitted)
        // If contents(forType:) throws, UIKit deliberately omits save/autosave/
        // close completion callbacks. Resolve those waits from its error channel.
        operations.failPending()
    }
}

/// UIKit can deliver errors and completion callbacks on different queues.
/// Taking a continuation out of the registry guarantees exactly one resolution.
private final class DocumentOperations: Sendable {
    private let pending = Mutex<[UUID: CheckedContinuation<Bool, Never>]>([:])

    func register(_ continuation: CheckedContinuation<Bool, Never>, id: UUID) {
        pending.withLock { $0[id] = continuation }
    }

    func complete(id: UUID, success: Bool) {
        pending.withLock { $0.removeValue(forKey: id) }?.resume(returning: success)
    }

    func failPending() {
        let continuations = pending.withLock { values in
            let result = Array(values.values)
            values.removeAll()
            return result
        }
        for continuation in continuations { continuation.resume(returning: false) }
    }
}
