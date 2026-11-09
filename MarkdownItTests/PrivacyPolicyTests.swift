import SwiftUI
import UIKit
import WebKit
import XCTest

@testable import MarkdownIt

final class PrivacyPolicyTests: XCTestCase {
    func testBundledNativeContentPreservesLanguagesStructureAndLinks() throws {
        for (language, firstTitle, lastTitle) in [
            ("zh-Hans", "1. 适用范围", "9. 政策更新与联系"),
            ("en", "1. Scope", "9. Updates and contact"),
        ] {
            let policy = try PrivacyPolicyContent.load(language: language)
            var headings: [String] = []
            var tables = 0
            var lists = 0
            for block in policy.blocks {
                switch block {
                case .heading(let text): headings.append(text.map(\.text).joined())
                case .table(let rows):
                    tables += 1
                    XCTAssertEqual(rows.count, 7)
                    XCTAssertTrue(rows.allSatisfy { $0.count == 2 })
                case .list(let items):
                    lists += 1
                    XCTAssertFalse(items.isEmpty)
                case .paragraph: break
                }
            }
            XCTAssertEqual(headings.count, 9)
            XCTAssertEqual(headings.first, firstTitle)
            XCTAssertEqual(headings.last, lastTitle)
            XCTAssertEqual(tables, 1)
            XCTAssertEqual(lists, 2)
            guard case .paragraph(let metadata) = try XCTUnwrap(policy.blocks.first) else {
                return XCTFail("The policy must start with its publication details")
            }
            let attributed = PrivacyPolicyContent.attributed(metadata)
            XCTAssertTrue(String(attributed.characters).contains("CHENXI LI"))
            XCTAssertTrue(String(attributed.characters).contains("lichenxi.catapple@gmail.com"))
            XCTAssertEqual(attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.count, 3)
            XCTAssertEqual(attributed.runs.compactMap(\.link), [URL(string: "mailto:lichenxi.catapple@gmail.com")!])
            XCTAssertNil(
                Bundle.main.url(forResource: "privacy-" + language, withExtension: "html", subdirectory: "Web"))
        }
        let fallback = try PrivacyPolicyContent.load(language: "fr")
        guard case .heading(let title) = fallback.blocks.dropFirst().first else {
            return XCTFail("Unsupported languages must use the English policy")
        }
        XCTAssertEqual(title.map(\.text).joined(), "1. Scope")
    }

    @MainActor
    func testNativeScrollViewportCoversModalAndAdaptsToLargeText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var normalContentHeight: CGFloat = 0
        for size in [DynamicTypeSize.large, .accessibility5] {
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: PrivacyLayoutHost(size: size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
            var scroll: UIScrollView?
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let modal = host.presentedViewController, !modal.isBeingPresented {
                    scroll = descendants(modal.view).compactMap { $0 as? UIScrollView }
                        .first { $0.contentSize.height > $0.bounds.height && $0.bounds.height > 0 }
                    if scroll != nil { break }
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            let modal = try XCTUnwrap(host.presentedViewController)
            let viewport = try XCTUnwrap(scroll)
            let frame = viewport.convert(viewport.bounds, to: modal.view)
            XCTAssertFalse(descendants(modal.view).contains { $0 is WKWebView })
            XCTAssertEqual(
                frame.maxY, modal.view.bounds.maxY, accuracy: 1, "A safe-area gap must not cut off policy scrolling")
            XCTAssertLessThanOrEqual(viewport.contentSize.width, viewport.bounds.width + 1)
            if size == .large {
                normalContentHeight = viewport.contentSize.height
            } else {
                XCTAssertGreaterThan(viewport.contentSize.height, normalContentHeight * 1.5)
            }
            await withCheckedContinuation { continuation in
                host.dismiss(animated: false) { continuation.resume() }
            }
        }
    }
}

private struct PrivacyLayoutHost: View {
    let size: DynamicTypeSize

    var body: some View {
        Color.clear.sheet(isPresented: .constant(true)) {
            PrivacyPolicyView().environment(\.dynamicTypeSize, size)
        }
    }
}
