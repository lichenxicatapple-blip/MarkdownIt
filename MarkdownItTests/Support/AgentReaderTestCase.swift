import UIKit
import WebKit
import XCTest

@testable import MarkdownIt

extension XCTestCase {
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
        _ text: String, api: ModelAPIProtocol = .chatCompletions,
        baseURL: String, model: String,
        modelClient: ModelClient, modelKey: @escaping @MainActor () -> String,
        dataSharingAllowed: Bool = true, recoveryStore: ReaderRecoveryStore? = nil
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
        defaults.set(api.rawValue, forKey: "model.apiProtocol")
        let session = ReaderSession(
            defaults: defaults,
            modelClient: modelClient,
            modelKey: modelKey, modelSettings: isolatedModelSettings(), recoveryStore: recoveryStore)
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
        let (bridge, window) = try await mountReader(session)
        return (session, bridge, window, url)
    }

    func mountReader(_ session: ReaderSession) async throws -> (ReaderBridge, UIWindow) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let bridge = ReaderBridge(session: session)
        // Register cleanup before readiness can throw, not after a successful setup.
        addTeardownBlock { @MainActor in
            bridge.detach()
            window.isHidden = true
            if previousKeyWindow?.isHidden == false { previousKeyWindow?.makeKey() }
        }
        window.makeKeyAndVisible()
        bridge.webView.frame = controller.view.bounds
        bridge.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(bridge.webView)
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
        _ = try await bridge.webView.callAsyncJavaScript(
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
