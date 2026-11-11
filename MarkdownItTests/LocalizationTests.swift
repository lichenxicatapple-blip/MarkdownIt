import UIKit
import WebKit
import XCTest

@testable import MarkdownIt

final class LocalizationTests: XCTestCase {
    private func localizedBundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    func testPackagedLanguagesIncludeNativeAndPermissionStrings() throws {
        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
        for (language, open, purpose) in [
            ("en", "Open Document", "Connect to the local model service you configure."),
            ("zh-Hans", "打开文档", "连接你设置的本地模型服务。"),
        ] {
            let bundle = try localizedBundle(language)
            XCTAssertEqual(String(localized: "Open Document", bundle: bundle), open)
            XCTAssertEqual(
                bundle.localizedString(forKey: "NSLocalNetworkUsageDescription", value: nil, table: "InfoPlist"),
                purpose)
        }
    }

    func testInterpolatedErrorsPreserveProviderDetailsInBothLanguages() throws {
        let code = 429
        let detail = "provider detail / 模型信息"
        for (language, expected) in [
            ("en", "The model service returned HTTP 429. \(detail)"),
            ("zh-Hans", "模型服务返回 HTTP 429。\(detail)"),
        ] {
            let bundle = try localizedBundle(language)
            XCTAssertEqual(
                String(localized: "The model service returned HTTP \(code). \(detail)", bundle: bundle),
                expected)
        }
    }

    @MainActor
    func testWebLanguageAndFallbackPreserveDocumentText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown =
            "# 保留原文\n\nEnglish and 中文 stay as written.\n\n<span class=\"author-text\" data-l10n=\"Contents\">作者自己的文字</span>\n"
        let file = root.appendingPathComponent("阅读.md")
        try Data(markdown.utf8).write(to: file)
        for (preferred, language, contents, source, send, retry) in [
            ("en", "en", "Contents", "Markdown source", "Send message", "^Retry in 1 second$"),
            ("zh-Hans", "zh-Hans", "文章目录", "Markdown 源码", "发送问题", "^1\\s*秒(?:钟)?后重试$"),
            ("fr", "en", "Contents", "Markdown source", "Send message", "^Retry in 1 second$"),
        ] {
            let defaultsName = UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let session = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
            await session.grant(root)
            await session.open(file)
            let bridge = ReaderBridge(session: session)
            for surface in [bridge.webView, bridge.conversationWebView] {
                surface.configuration.userContentController.addUserScript(
                    WKUserScript(
                        source: "window.MarkdownItLanguages = ['\(preferred)'];",
                        injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            let controller = UIViewController()
            window.rootViewController = controller
            window.makeKeyAndVisible()
            bridge.webView.frame = CGRect(x: 0, y: 0, width: 1024, height: 900)
            let readerContainer = ReaderContainer(webView: bridge.webView)
            readerContainer.frame = bridge.webView.frame
            readerContainer.autoresizingMask = bridge.webView.autoresizingMask
            controller.view.addSubview(readerContainer)
            defer {
                bridge.detach()
                window.isHidden = true
            }
            let deadline = Date().addingTimeInterval(25)
            while !session.rendererReady && Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(session.rendererReady)
            let result = try await bridge.webView.evaluateJavaScript(
                """
                (() => {
                  const { t, formatSeconds } = window.MarkdownItLocalization;
                  return { language: document.documentElement.lang,
                    contents: document.querySelector('.mdv-outline').getAttribute('aria-label'),

                    retry: t('Retry in {duration}', { duration: formatSeconds(1) }),
                    author: document.querySelector('.mdv-article .author-text').textContent };
                })()
                """)
            let values = try XCTUnwrap(result as? [String: String])
            XCTAssertEqual(values["language"], language)
            XCTAssertEqual(values["contents"], contents)
            let nativeBundle = try localizedBundle(language)
            XCTAssertEqual(String(localized: "Markdown source", bundle: nativeBundle), source)
            XCTAssertEqual(bridge.sourceEditor.textView.accessibilityLabel, String(localized: "Markdown source"))
            let webSend =
                try await bridge.conversationWebView.evaluateJavaScript(
                    "document.querySelector('.mdv-agent-send').getAttribute('aria-label')") as? String
            XCTAssertEqual(webSend, send)
            // ICU versions may use either 秒 or 秒钟 for the long Chinese unit.
            XCTAssertNotNil(values["retry"]?.range(of: retry, options: .regularExpression))
            XCTAssertEqual(values["author"], "作者自己的文字")
            _ = try await bridge.call("toggleMode")
            let sourceText = bridge.flushSource()
            XCTAssertEqual(sourceText, markdown)
            XCTAssertEqual(session.document?.text, markdown)
            await session.closeDocument()
        }
    }
}
