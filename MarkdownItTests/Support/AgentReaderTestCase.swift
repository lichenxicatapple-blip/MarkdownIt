import UIKit
import WebKit
import XCTest

@testable import MarkdownIt

extension XCTestCase {
    @MainActor
    func isolatedPasteboard() -> UIPasteboard {
        let pasteboard = UIPasteboard.withUniqueName()
        addTeardownBlock { @MainActor in UIPasteboard.remove(withName: pasteboard.name) }
        return pasteboard
    }

    func isolatedModelSettings() -> ModelSettingsStore {
        let store = ModelSettingsStore(service: "dev.catli.MarkdownIt.model.unit-testing." + UUID().uuidString)
        addTeardownBlock {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: store.service))
            try store.reset(clearingLegacyIn: defaults)
            defaults.removePersistentDomain(forName: store.service)
        }
        return store
    }
}

/// A rendered document fixture with explicit transport and credential dependencies.
@MainActor
class AgentReaderTestCase: XCTestCase {
    func recordWindow(_ name: String, window: UIWindow, rect: CGRect) {
        let crop = rect.intersection(window.bounds)
        let image = UIGraphicsImageRenderer(size: crop.size).image { context in
            context.cgContext.translateBy(x: -crop.minX, y: -crop.minY)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func wait(
        timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Agent did not reach its expected state", file: file, line: line)
        throw ModelError.invalidResponse
    }

    func makeReader(
        _ text: String,
        baseURL: String, model: String,
        modelClient: ModelClient, modelKey: @escaping @MainActor () -> String,
        dataSharingAllowed: Bool = true, recoveryStore: ReaderRecoveryStore? = nil,
        modelCatalog: ModelCatalog? = nil, webSearchClient: WebSearchClient? = nil,
        conversationStore: AgentConversationStore? = nil, pasteboard: UIPasteboard = .general
    ) async throws -> (
        ReaderSession, ReaderBridge, UIWindow, URL
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("agent-test.md")
        try Data(text.utf8).write(to: url)
        let defaultsName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(baseURL, forKey: "model.baseURL")
        defaults.set(model, forKey: "model.id")
        let session = ReaderSession(
            defaults: defaults,
            modelClient: modelClient,
            modelCatalog: modelCatalog ?? ModelCatalog(session: modelClient.session),
            webSearchClient: webSearchClient ?? WebSearchClient(),
            modelKey: modelKey, modelSettings: isolatedModelSettings(), recoveryStore: recoveryStore,
            annotationStore: ReadingAnnotationStore(
                directory: (recoveryStore?.directory.deletingLastPathComponent() ?? root).appendingPathComponent(
                    "Annotations")), conversationStore: conversationStore)
        addTeardownBlock { @MainActor in
            if let document = session.document, !document.documentState.contains(.closed) {
                await session.closeDocument()
            }
        }
        if dataSharingAllowed, let service = try? ModelDataConsent.service(for: session.configuration) {
            session.dataConsent.allow(service)
        }
        await session.grant(root)
        await session.open(url)
        _ = try XCTUnwrap(session.document, session.errorMessage ?? "The fixture document must open before rendering")
        let (bridge, window) = try await mountReader(session, pasteboard: pasteboard)
        return (session, bridge, window, url)
    }

    func mountReader(_ session: ReaderSession, pasteboard: UIPasteboard = .general) async throws -> (
        ReaderBridge, UIWindow
    ) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let bridge = ReaderBridge(session: session, pasteboard: pasteboard)
        // Register cleanup before readiness can throw, not after a successful setup.
        addTeardownBlock { @MainActor in
            bridge.detach()
            window.isHidden = true
            if previousKeyWindow?.isHidden == false { previousKeyWindow?.makeKey() }
        }
        window.makeKeyAndVisible()
        bridge.webView.frame = controller.view.bounds
        bridge.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let readerContainer = ReaderContainer(webView: bridge.webView)
        readerContainer.frame = bridge.webView.frame
        readerContainer.autoresizingMask = bridge.webView.autoresizingMask
        controller.view.addSubview(readerContainer)
        // Hosted simulators can spend over 30 seconds launching a WebContent
        // process before this page runs. Keep that budget separate from actions.
        try await wait(timeout: 60) {
            if let error = session.errorMessage {
                throw NSError(domain: "ReaderFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
            }
            return session.rendererReady && bridge.ready
        }
        return (bridge, window)
    }

    func state(_ bridge: ReaderBridge) async throws -> [String: Any] {
        let result = try await bridge.call("agentDiagnostics")
        return try XCTUnwrap(result as? [String: Any])
    }

    func send(_ text: String, bridge: ReaderBridge) async throws {
        try await wait {
            let status = try await self.state(bridge)
            return status["open"] as? Bool == true
        }
        _ = try await bridge.conversationWebView.callAsyncJavaScript(
            "const field = document.querySelector(selector); field.value = text; field.dispatchEvent(new Event('input',{bubbles:true})); field.form.requestSubmit();",
            arguments: ["text": text, "selector": ".mdv-composer textarea"],
            in: nil, contentWorld: .page)
    }

    func sourceMode(_ bridge: ReaderBridge) async throws {
        _ = try await bridge.call("toggleMode")
        try await wait {
            let mode = (try await bridge.call("diagnostics") as? [String: Any])?["mode"] as? String
            let transitioning =
                try await bridge.webView.evaluateJavaScript(
                    "Boolean(document.querySelector('.mdv-app').dataset.modeTransition)") as? Bool
            return mode == "source" && transitioning == false
        }
    }
}
