import XCTest

@testable import MarkdownIt

final class ResourceAccessTests: XCTestCase {
    func testRecentRootSelectionKeepsDocumentAndImageFoldersWithoutUnrelatedGrants() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
        let access = ResourceAccess(
            documentURL: notes.appendingPathComponent("readme.md"), roots: [notes, assets, unrelated], token: "test")
        XCTAssertEqual(access.rootsRequired(for: []), [notes])
        XCTAssertEqual(access.rootsRequired(for: ["../assets/figure.svg"]), [notes, assets])
    }

    func testRelativePathsUseDocumentLocationAndRespectGrantedAncestor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let figures = root.appendingPathComponent("插图", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: figures, withIntermediateDirectories: true)
        let document = notes.appendingPathComponent("guide.md")
        let image = figures.appendingPathComponent("system diagram.svg")
        let access = ResourceAccess(documentURL: document, roots: [root], token: "test")
        XCTAssertEqual(
            try access.resolve("../%E6%8F%92%E5%9B%BE/system%20diagram.svg?version=1#figure"), image.standardizedFileURL
        )
        XCTAssertEqual(try access.resolve("assets/figure.png"), notes.appendingPathComponent("assets/figure.png"))
        XCTAssertEqual(try access.resolve("image.png"), notes.appendingPathComponent("image.png"))
        let onlyFile = ResourceAccess(documentURL: document, roots: [], token: "test")
        XCTAssertNoThrow(try onlyFile.resolve("guide.md"))
        XCTAssertThrowsError(try onlyFile.resolve("image.png"))
        XCTAssertThrowsError(try access.resolve("../../outside.png"))
        XCTAssertThrowsError(try access.resolve("https://example.com/image.png"))
    }

    func testSymlinkCannotEscapeGrantedFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        let access = ResourceAccess(documentURL: root.appendingPathComponent("guide.md"), roots: [root], token: "test")
        XCTAssertThrowsError(try access.resolve("escape/private.png"))
        XCTAssertThrowsError(try access.resolve("bad\0name"))
    }

    func testPermissionDirectoriesFollowReferencesWithoutInventingCommonAncestors() {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let notes = project.appendingPathComponent("文档", isDirectory: true)
        let images = notes.appendingPathComponent("images", isDirectory: true)
        let assets = project.appendingPathComponent("assets", isDirectory: true)
        var access = ResourceAccess(documentURL: notes.appendingPathComponent("阅读.md"), roots: [], token: "test")
        let paths = ["images/本地图片.png", "../assets/关系图.svg?version=1#diagram"]
        XCTAssertEqual(access.directoriesRequiringAccess(for: paths).map(\.path), [images.path, assets.path])
        XCTAssertEqual(access.directoryRequiringAccess(for: paths)?.path, images.path)
        XCTAssertEqual(
            access.directoriesRequiringAccess(for: paths.reversed()).map(\.path), [assets.path, images.path])
        XCTAssertEqual(
            access.directoriesRequiringAccess(for: ["images/a.png", "images/child/b.png"]).map(\.path), [images.path])
        access.roots = [assets]
        XCTAssertEqual(access.directoriesRequiringAccess(for: paths).map(\.path), [images.path])
        access.roots = [project]
        XCTAssertNil(access.directoryRequiringAccess(for: paths))
        XCTAssertNil(access.directoryRequiringAccess(for: ["https://example.com/image.png", "bad\0name"]))
        XCTAssertEqual(
            access.directoriesRequiringAccess(for: ["/first/a.png", "/second/b.png"]).map(\.path),
            ["/first", "/second"])
        XCTAssertNil(access.directoryRequiringAccess(for: ["/image.png"]), "The filesystem root must never be proposed")
    }

    @MainActor
    func testLocalDocumentLinkRequestsItsFolderWithoutLeavingCurrentDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let chapters = root.appendingPathComponent("Linked Chapters", isDirectory: true)
        for folder in [notes, chapters] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let file = notes.appendingPathComponent("index.md")
        try Data("# Index\n".utf8).write(to: file)
        try Data("# Chapter\n".utf8).write(to: chapters.appendingPathComponent("chapter.md"))
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        await session.open(file)
        let token = session.documentToken

        await session.resolveLink("../Linked%20Chapters/chapter.md#section")

        XCTAssertNotNil(session.resourcePermission, "A denied local document link must offer folder authorization")
        XCTAssertEqual(session.resourcePermission?.directory.path, chapters.path)
        XCTAssertNil(session.errorMessage, "Authorization must be actionable, not an error with only an OK button")
        XCTAssertEqual(session.documentToken, token)
        XCTAssertEqual(session.document?.fileURL, file)
        await session.closeDocument()
    }

    @MainActor
    func testLocalDocumentPermissionValidatesSelectionAndContinuesTheOriginalLink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let chapters = root.appendingPathComponent("chapters", isDirectory: true)
        for folder in [notes, chapters] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let index = notes.appendingPathComponent("index.md")
        let chapter = chapters.appendingPathComponent("one.md")
        let next = chapters.appendingPathComponent("two.md")
        for file in [index, chapter, next] { try Data("# \(file.lastPathComponent)\n".utf8).write(to: file) }
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        await session.open(index)
        let token = session.documentToken
        await session.resolveLink("../chapters/one.md")
        let request = try XCTUnwrap(session.resourcePermission)
        XCTAssertEqual(request.purpose, .document(link: "../chapters/one.md"))

        // A late image failure must not replace an explicit document-open request.
        session.localResourcesChanged(["images/figure.svg"], token: token)
        session.resources.onPermissionDenied?(token, "images/figure.svg")
        XCTAssertEqual(session.resourcePermission?.id, request.id)
        let rejected = await session.finishResourcePermission(notes, requestID: request.id)
        XCTAssertFalse(rejected)
        XCTAssertEqual(session.resourcePermission?.id, request.id)
        XCTAssertEqual(session.document?.fileURL, index)

        let accepted = await session.finishResourcePermission(chapters, requestID: request.id)
        XCTAssertTrue(accepted)
        XCTAssertEqual(session.document?.fileURL, chapter)
        XCTAssertNil(session.resourcePermission)
        XCTAssertNil(session.errorMessage)
        XCTAssertTrue(session.recentDocuments.documents.contains { $0.folders.contains { $0.url == chapters } })
        await session.resolveLink("two.md")
        XCTAssertEqual(session.document?.fileURL, next, "An already authorized folder must not prompt again")
        XCTAssertNil(session.resourcePermission)
        await session.closeDocument()
    }

    @MainActor
    func testCancelledAndOldDocumentPickerResultsCannotOpenTheLinkedDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("index.md")
        let chapter = root.appendingPathComponent("chapter.md")
        let other = root.appendingPathComponent("other.md")
        for file in [index, chapter, other] { try Data("# \(file.lastPathComponent)\n".utf8).write(to: file) }
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        await session.open(index)
        await session.resolveLink("chapter.md")
        let cancelled = try XCTUnwrap(session.resourcePermission)
        session.cancelResourcePermission()
        let late = await session.finishResourcePermission(root, requestID: cancelled.id)
        XCTAssertFalse(late)
        XCTAssertEqual(session.document?.fileURL, index)
        XCTAssertNil(session.resourcePermission)

        await session.resolveLink("chapter.md")
        let repeated = try XCTUnwrap(session.resourcePermission)
        XCTAssertNotEqual(repeated.id, cancelled.id)
        session.cancelResourcePermission(requestID: cancelled.id)
        XCTAssertEqual(session.resourcePermission?.id, repeated.id, "An old picker cannot cancel the new request")
        await session.open(other)
        let stale = await session.finishResourcePermission(root, requestID: repeated.id)
        XCTAssertFalse(stale)
        XCTAssertEqual(session.document?.fileURL, other)
        XCTAssertNil(session.resourcePermission)
        await session.closeDocument()
    }

    @MainActor
    func testNonMarkdownLinksDoNotRequestFolderPermission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.md")
        try Data("# Index\n".utf8).write(to: file)
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        await session.open(file)
        for link in ["../images/figure.svg", "../notes/example.txt"] {
            await session.resolveLink(link)
            XCTAssertNil(session.resourcePermission)
            XCTAssertNil(session.errorMessage)
            XCTAssertEqual(session.document?.fileURL, file)
        }
        await session.closeDocument()
    }

    @MainActor
    func testPermissionRequestWaitsForAllDocumentPathsAndIgnoresAnOldDocument() async throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let notes = project.appendingPathComponent("文档", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let file = notes.appendingPathComponent("阅读.md")
        try Data("# Local images\n".utf8).write(to: file)
        let session = ReaderSession(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, modelSettings: isolatedModelSettings())
        await session.open(file)
        let token = session.documentToken
        session.resources.onPermissionDenied?(token, "images/本地图片.png")
        XCTAssertNil(
            session.resourcePermission,
            "The inventory determines request order, not whichever image failed first")
        session.localResourcesChanged(["images/本地图片.png"], token: "old-document")
        XCTAssertNil(session.resourcePermission)
        session.localResourcesChanged(["images/本地图片.png", "../assets/关系图.svg"], token: token)
        XCTAssertNotNil(session.resourcePermission)
        XCTAssertEqual(session.resourcePermission?.directory.path, notes.appendingPathComponent("images").path)
        session.cancelResourcePermission()
        session.localResourcesChanged(["images/本地图片.png"], token: token)
        XCTAssertNil(session.resourcePermission, "Cancel must not reopen the prompt on a later render")
        session.resources.onPermissionDenied?(token, "images/本地图片.png")
        XCTAssertNotNil(session.resourcePermission, "The inventory-first delivery order also works")
        XCTAssertEqual(session.resourcePermission?.directory.path, notes.appendingPathComponent("images").path)
        await session.closeDocument()
        XCTAssertNil(session.resourcePermission?.directory)
        session.resources.onPermissionDenied?(token, "image.png")
        XCTAssertNil(session.resourcePermission)
    }
}
