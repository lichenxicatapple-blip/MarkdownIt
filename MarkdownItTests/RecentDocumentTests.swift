import SwiftUI
import XCTest

@testable import MarkdownIt

final class RecentDocumentTests: XCTestCase {
    @MainActor
    func testRecentListFitsAHeightConstrainedPopover() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentDocumentsStore(defaults: defaults)
        for number in 0..<10 {
            let file = URL(fileURLWithPath: "/tmp/recent-\(number).md")
            store.record(await RecentDocumentsStore.prepare(file, folders: []))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        for textSize in [DynamicTypeSize.large, .accessibility3] {
            let host = UIHostingController(
                rootView: RecentDocumentsView(store: store, compact: false, open: { _ in false })
                    .environment(\.dynamicTypeSize, textSize))
            controller.addChild(host)
            controller.view.addSubview(host.view)
            host.didMove(toParent: controller)
            defer {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
            }
            for height: CGFloat in [230, 540, 230] {
                host.view.frame = CGRect(x: 0, y: 50, width: ReaderDesign.recentsWidth, height: height)
                var list: UICollectionView?
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline {
                    host.view.layoutIfNeeded()
                    list = descendants(host.view).compactMap { $0 as? UICollectionView }.first
                    if let list, !list.visibleCells.isEmpty { break }
                    try await Task.sleep(for: .milliseconds(40))
                }
                let viewport = try XCTUnwrap(list)
                viewport.setContentOffset(CGPoint(x: 0, y: -viewport.adjustedContentInset.top), animated: false)
                viewport.layoutIfNeeded()
                let frame = viewport.convert(viewport.bounds, to: host.view)
                let first = try XCTUnwrap(viewport.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
                let firstFrame = viewport.convert(first.frame, to: host.view)
                let message = "Popover height \(height), text size \(textSize)"
                XCTAssertGreaterThanOrEqual(frame.minY, host.view.bounds.minY - 1, message)
                XCTAssertLessThanOrEqual(frame.maxY, host.view.bounds.maxY + 1, message)
                XCTAssertGreaterThanOrEqual(firstFrame.minY, host.view.bounds.minY - 1, message)
                XCTAssertLessThanOrEqual(firstFrame.maxY, host.view.bounds.maxY + 1, message)
                let navigationBar = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UINavigationBar }.first)
                let titleFrame = navigationBar.convert(navigationBar.bounds, to: host.view)
                XCTAssertGreaterThanOrEqual(titleFrame.minY, host.view.bounds.minY - 1, message)
                XCTAssertLessThanOrEqual(titleFrame.maxY, host.view.bounds.maxY + 1, message)
                let lastPath = IndexPath(item: store.documents.count - 1, section: 0)
                viewport.scrollToItem(at: lastPath, at: .bottom, animated: false)
                viewport.layoutIfNeeded()
                let last = try XCTUnwrap(viewport.layoutAttributesForItem(at: lastPath))
                let lastFrame = viewport.convert(last.frame, to: host.view)
                XCTAssertGreaterThanOrEqual(lastFrame.minY, host.view.bounds.minY - 1, message)
                XCTAssertLessThanOrEqual(lastFrame.maxY, host.view.bounds.maxY + 1, message)
            }
        }
    }

    private func invalidBookmark(_ url: URL) throws -> BookmarkedLocation {
        let data = try JSONSerialization.data(withJSONObject: [
            "url": url.absoluteString, "bookmark": Data("invalid bookmark".utf8).base64EncodedString(),
        ])
        return try JSONDecoder().decode(BookmarkedLocation.self, from: data)
    }

    @MainActor
    func testAppOwnedRecentFileCanRecoverFromAnInvalidBookmark() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        try Data("# Local document\n".utf8).write(to: file)
        let recent = RecentDocument(
            id: UUID(), file: try invalidBookmark(file), identity: file, folders: [])
        let session = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        let opened = try await session.openRecent(recent)
        XCTAssertTrue(opened)
        XCTAssertEqual(session.document?.text, "# Local document\n")
        XCTAssertEqual(session.recentDocuments.documents.first?.id, recent.id)
        await session.closeDocument()
    }

    func testInvalidExternalBookmarkCannotUseAnAppOwnedSymlinkToBypassResolution() throws {
        let external = try XCTUnwrap(
            Bundle.main.url(forResource: "reading-guide", withExtension: "md", subdirectory: "Sample"))
        XCTAssertFalse(BookmarkedLocation.isAppOwned(external))
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        for url in [external, link] {
            XCTAssertFalse(BookmarkedLocation.isAppOwned(url))
            XCTAssertThrowsError(try invalidBookmark(url).resolve())
        }
    }

    @MainActor
    func testHistoryKeepsTenDistinctDocumentsInLastOpenedOrderAcrossReload() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = RecentDocumentsStore(defaults: defaults)
        for number in 0..<12 {
            let url = root.appendingPathComponent("文档 \(number).md")
            try Data("# \(number)\n".utf8).write(to: url)
            store.record(await RecentDocumentsStore.prepare(url, folders: []))
        }
        XCTAssertEqual(store.documents.map(\.name), (2..<12).reversed().map { "文档 \($0).md" })
        let repeated = try XCTUnwrap(store.documents.first { $0.name == "文档 5.md" })
        store.record(await RecentDocumentsStore.prepare(repeated.file.url, folders: []))
        XCTAssertEqual(store.documents.count, 10)
        XCTAssertEqual(store.documents.first?.id, repeated.id)
        XCTAssertEqual(store.documents.filter { $0.name == repeated.name }.count, 1)
        let loaded = RecentDocumentsStore(defaults: defaults)
        XCTAssertEqual(loaded.documents, store.documents)
        XCTAssertNotNil(loaded.documents.first?.file.bookmark)
        let resolved = try await loaded.resolve(XCTUnwrap(loaded.documents.first))
        XCTAssertEqual(resolved.file.resolvingSymlinksInPath(), repeated.file.url.resolvingSymlinksInPath())
    }

    @MainActor
    func testFailedRecentOpenPreservesCurrentDocumentAndHistory() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let session = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try Data("# First\n".utf8).write(to: first)
        try Data("# Second\n".utf8).write(to: second)
        await session.open(first)
        await session.closeDocument()
        let missing = try XCTUnwrap(session.recentDocuments.documents.first)
        try FileManager.default.removeItem(at: first)
        await session.open(second)
        let history = session.recentDocuments.documents
        let token = session.documentToken
        do {
            _ = try await session.openRecent(missing)
            XCTFail("A deleted document must not reopen")
        } catch {}
        XCTAssertEqual(session.recentDocuments.documents, history)
        XCTAssertEqual(session.documentToken, token)
        XCTAssertEqual(session.document?.text, "# Second\n")
        await session.open(root.appendingPathComponent("never-opened.md"))
        XCTAssertEqual(session.recentDocuments.documents, history)
        await session.closeDocument()
    }

    @MainActor
    func testCorruptHistoryDoesNotPreventOpeningAndCanBeReplaced() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid history".utf8), forKey: RecentDocumentsStore.storageKey)
        let store = RecentDocumentsStore(defaults: defaults)
        XCTAssertTrue(store.documents.isEmpty)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("# Recovered\n".utf8).write(to: file)
        store.record(await RecentDocumentsStore.prepare(file, folders: []))
        XCTAssertEqual(RecentDocumentsStore(defaults: defaults).documents.count, 1)
    }
}
