import XCTest

@testable import MarkdownIt

final class DocumentTests: XCTestCase {
    @MainActor
    func testUnsupportedDocumentDoesNotReplaceCurrentDocumentOrHistory() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let session = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        let original = root.appendingPathComponent("original.md")
        try Data("# Original\n".utf8).write(to: original)
        await session.open(original)
        let document = try XCTUnwrap(session.document)
        let token = session.documentToken
        let history = session.recentDocuments.documents
        for name in ["other.txt", "other.html", "other.pdf", "other.png", "no-extension", "other.md.txt"] {
            let url = root.appendingPathComponent(name)
            try Data("# Valid text, unsupported filename\n".utf8).write(to: url)
            await session.open(url)
            guard session.document === document else {
                XCTFail("An unsupported filename must not replace the current document: \(name)")
                await session.closeDocument()
                return
            }
            XCTAssertEqual(session.documentToken, token)
            XCTAssertEqual(session.recentDocuments.documents, history)
            XCTAssertNotNil(session.errorMessage)
        }
        let unsupported = await RecentDocumentsStore.prepare(root.appendingPathComponent("other.txt"), folders: [])
        do {
            _ = try await session.openRecent(unsupported)
            XCTFail("The recent-document entry point must enforce the same file types")
        } catch {}
        XCTAssertTrue(session.document === document)
        XCTAssertEqual(session.documentToken, token)
        XCTAssertEqual(session.recentDocuments.documents, history)
        await session.closeDocument()
    }

    @MainActor
    func testMarkdownAliasesAndUppercaseExtensionsOpenInPlace() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let declarations = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]])
        let markdown = try XCTUnwrap(
            declarations.first { $0["UTTypeIdentifier"] as? String == "net.daringfireball.markdown" })
        let tags = try XCTUnwrap(markdown["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(
            Set(try XCTUnwrap(tags["public.filename-extension"] as? [String])),
            Set(MarkdownDocument.supportedFilenameExtensions))
        let session = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        for (index, ext) in ["md", "MD", "markdown", "mArKdOwN", "mdown", "mkd"].enumerated() {
            let url = root.appendingPathComponent("document-\(index).\(ext)")
            try Data("# Markdown\n".utf8).write(to: url)
            await session.open(url)
            XCTAssertEqual(session.document?.fileURL.standardizedFileURL, url.standardizedFileURL)
            XCTAssertEqual(session.document?.text, "# Markdown\n")
            await session.closeDocument()
        }
    }

    @MainActor
    func testCloseSavesInPlaceResetsReaderAndIgnoresLateEdits() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("# Original\n".utf8).write(to: url)
        let session = ReaderSession(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, modelSettings: isolatedModelSettings())
        await session.open(url)
        let token = session.documentToken
        let document = try XCTUnwrap(session.document)
        session.sourceChanged("# Saved before closing\n", token: token)
        session.agentOpen = true
        session.outlineExpanded = true
        session.hasOutline = true
        await session.closeDocument()
        XCTAssertNil(session.document)
        XCTAssertNotEqual(session.documentToken, token)
        XCTAssertTrue(document.documentState.contains(.closed))
        XCTAssertFalse(session.agentOpen)
        XCTAssertFalse(session.outlineExpanded)
        XCTAssertFalse(session.hasOutline)
        XCTAssertFalse(session.closeSaveFailed)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Saved before closing\n")
        session.sourceChanged("# Stale callback\n", token: token)
        await session.flushChanges()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Saved before closing\n")
        await session.open(url)
        XCTAssertEqual(session.document?.text, "# Saved before closing\n")
        await session.closeDocument()
    }

    @MainActor
    func testFailedSavePreventsReplacingTheCurrentDocumentUntilUserRetries() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try Data("# First\n".utf8).write(to: first)
        try Data("# Second\n".utf8).write(to: second)
        let session = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        await session.open(first)
        let original = try XCTUnwrap(session.document)
        let token = session.documentToken
        let history = session.recentDocuments.documents
        session.sourceChanged("# Unsaved first\n", token: token)
        original.failNextWritesForTesting(1)

        await session.open(second)
        XCTAssertTrue(session.document === original, "A replacement must not silently retry a failed save")
        XCTAssertEqual(session.documentToken, token)
        XCTAssertEqual(session.recentDocuments.documents, history)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertEqual(original.text, "# Unsaved first\n")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# First\n")

        await session.open(second)
        XCTAssertEqual(session.document?.fileURL, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# Unsaved first\n")
        await session.closeDocument()
    }

    @MainActor
    func testFailedClosePreservesEditsAndRetryCanSave() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("# Original\n".utf8).write(to: url)
        let session = ReaderSession(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, modelSettings: isolatedModelSettings())
        await session.open(url)
        let document = try XCTUnwrap(session.document)
        let token = session.documentToken
        document.failNextWritesForTesting(.max)
        session.sourceChanged("# Keep these edits\n", token: token)
        await session.closeDocument()
        XCTAssertTrue(session.closeSaveFailed)
        XCTAssertTrue(session.document === document)
        XCTAssertEqual(session.documentToken, token)
        XCTAssertEqual(document.text, "# Keep these edits\n")
        XCTAssertTrue(document.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Original\n")
        XCTAssertNil(session.errorMessage, "The dedicated close alert owns this failure")
        await session.flushChanges()
        XCTAssertNil(session.errorMessage, "Background flushing must not duplicate the close alert")
        document.failNextWritesForTesting(0)
        await session.closeDocument()
        XCTAssertNil(session.document)
        XCTAssertFalse(session.closeSaveFailed)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Keep these edits\n")
    }

    @MainActor
    func testFailedCloseCanCancelOrExplicitlyDiscardWithoutWriting() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("# Original\n".utf8).write(to: url)
        let session = ReaderSession(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, modelSettings: isolatedModelSettings())
        await session.open(url)
        let document = try XCTUnwrap(session.document)
        let token = session.documentToken
        session.sourceChanged("# Unsaved\n", token: token)
        await session.closeDocument(discardChanges: true)
        XCTAssertTrue(session.document === document, "Discard is only allowed after an explicit failed close")
        document.failNextWritesForTesting(.max)
        await session.closeDocument()
        XCTAssertTrue(session.closeSaveFailed)
        session.cancelDocumentClose()
        XCTAssertFalse(session.closeSaveFailed)
        XCTAssertTrue(session.document === document)
        XCTAssertTrue(document.hasUnsavedChanges)
        session.sourceChanged("# Still editable\n", token: token)
        await session.closeDocument()
        XCTAssertTrue(session.closeSaveFailed)
        // SwiftUI dismisses its alert binding before invoking the chosen action.
        session.closeSaveFailed = false
        await session.closeDocument(discardChanges: true)
        XCTAssertNil(session.document)
        XCTAssertTrue(document.documentState.contains(.closed))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Original\n")
        document.failNextWritesForTesting(0)
        await session.open(url)
        XCTAssertEqual(session.document?.text, "# Original\n")
        await session.closeDocument()
    }

    @MainActor
    func testReadOnlyCRLFRemainsUnchangedAndEditsPreserveNewlines() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("# Windows document\r\n\r\n原文。\r\n".utf8)
        try original.write(to: url)
        let session = ReaderSession(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, modelSettings: isolatedModelSettings())
        await session.open(url)
        XCTAssertEqual(session.document?.text, "# Windows document\n\n原文。\n")
        session.sourceChanged("# Windows document\n\n原文。\n", token: session.documentToken)
        await session.flushChanges()
        XCTAssertFalse(session.document?.hasUnsavedChanges ?? true)
        XCTAssertEqual(try Data(contentsOf: url), original)
        session.sourceChanged("# Windows document\n\n修改。\n", token: session.documentToken)
        await session.flushChanges()
        let closed = await session.document?.closeSavingChanges()
        XCTAssertEqual(closed, true)
        XCTAssertEqual(try Data(contentsOf: url), Data("# Windows document\r\n\r\n修改。\r\n".utf8))
    }

    @MainActor
    func testUTF16BigEndianBOMAndCRLFArePreserved() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        let bom = Data([0xFE, 0xFF])
        try (bom + XCTUnwrap("# 原文\r\n".data(using: .utf16BigEndian))).write(to: url)
        let document = MarkdownDocument(fileURL: url)
        let opened = await document.openForReading()
        XCTAssertTrue(opened)
        XCTAssertEqual(document.text, "# 原文\n")
        document.text = "# 修改\n"
        document.updateChangeCount(.done)
        let saved = await document.persist()
        XCTAssertTrue(saved)
        let closed = await document.closeSavingChanges()
        XCTAssertTrue(closed)
        XCTAssertEqual(try Data(contentsOf: url), try bom + XCTUnwrap("# 修改\r\n".data(using: .utf16BigEndian)))
    }

    @MainActor
    func testEditingPersistsInPlaceAndFailedOpenPreservesCurrentDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.md")
        try Data("# Original\n".utf8).write(to: url)
        let session = ReaderSession(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, modelSettings: isolatedModelSettings())
        await session.grant(root)
        await session.open(url)
        let originalToken = session.documentToken
        XCTAssertEqual(session.document?.text, "# Original\n")
        session.sourceChanged("# Edited\n中文内容和 code。\n", token: originalToken)
        await session.flushChanges()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Edited\n中文内容和 code。\n")
        session.sourceChanged("stale document", token: "another-document")
        XCTAssertNotEqual(session.document?.text, "stale document")
        await session.open(root.appendingPathComponent("missing.md"))
        XCTAssertEqual(session.document?.fileURL, url)
        XCTAssertEqual(session.documentToken, originalToken)
        XCTAssertNotNil(session.errorMessage)
        session.sourceChanged("# Still editable\n", token: originalToken)
        await session.flushChanges()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Still editable\n")
        let closed = await session.document?.closeSavingChanges()
        XCTAssertEqual(closed, true)
    }

    @MainActor
    func testUTF16DocumentRetainsEncodingAfterEdit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        try XCTUnwrap("# 原文\n".data(using: .utf16)).write(to: url)
        let document = MarkdownDocument(fileURL: url)
        let opened = await document.openForReading()
        XCTAssertTrue(opened)
        XCTAssertEqual(document.text, "# 原文\n")
        document.text = "# 修改\n"
        document.updateChangeCount(.done)
        let saved = await document.persist()
        XCTAssertTrue(saved)
        let closed = await document.closeSavingChanges()
        XCTAssertTrue(closed)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data, encoding: .utf16), "# 修改\n")
        XCTAssertNil(String(data: data, encoding: .utf8))
    }

    @MainActor
    func testUTF8BOMIsHiddenFromMarkdownAndPreservedOnSave() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        try (Data([0xEF, 0xBB, 0xBF]) + Data("# 标题\n".utf8)).write(to: url)
        let document = MarkdownDocument(fileURL: url)
        let opened = await document.openForReading()
        XCTAssertTrue(opened)
        XCTAssertEqual(document.text, "# 标题\n")
        document.text = "# 新标题\n"
        document.updateChangeCount(.done)
        let saved = await document.persist()
        XCTAssertTrue(saved)
        let closed = await document.closeSavingChanges()
        XCTAssertTrue(closed)
        XCTAssertEqual(try Data(contentsOf: url), Data([0xEF, 0xBB, 0xBF]) + Data("# 新标题\n".utf8))
    }
}
