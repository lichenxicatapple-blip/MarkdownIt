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
        XCTAssertFalse(
            session.needsResourcePermission, "The inventory determines request order, not whichever image failed first")
        session.localResourcesChanged(["images/本地图片.png"], token: "old-document")
        XCTAssertFalse(session.needsResourcePermission)
        session.localResourcesChanged(["images/本地图片.png", "../assets/关系图.svg"], token: token)
        XCTAssertTrue(session.needsResourcePermission)
        XCTAssertEqual(session.resourcePermissionDirectory?.path, notes.appendingPathComponent("images").path)
        session.needsResourcePermission = false
        session.localResourcesChanged(["images/本地图片.png"], token: token)
        XCTAssertFalse(session.needsResourcePermission, "Cancel must not reopen the prompt on a later render")
        session.resources.onPermissionDenied?(token, "images/本地图片.png")
        XCTAssertTrue(session.needsResourcePermission, "The inventory-first delivery order also works")
        XCTAssertEqual(session.resourcePermissionDirectory?.path, notes.appendingPathComponent("images").path)
        await session.closeDocument()
        XCTAssertNil(session.resourcePermissionDirectory)
        session.resources.onPermissionDenied?(token, "image.png")
        XCTAssertFalse(session.needsResourcePermission)
    }
}
