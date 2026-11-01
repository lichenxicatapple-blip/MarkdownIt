import SwiftUI
import UIKit

@main
struct MarkdownItApp: App {
    @StateObject private var session: ReaderSession
    @Environment(\.scenePhase) private var scenePhase

    init() {
        var defaults = UserDefaults.standard
        var modelClient = ModelClient()
        var modelCatalog = ModelCatalog()
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                let name = "dev.catli.MarkdownIt.ui-testing"
                defaults = UserDefaults(suiteName: name) ?? .standard
                if !ProcessInfo.processInfo.arguments.contains("--ui-test-keep-state") {
                    defaults.removePersistentDomain(forName: name)
                }
                try? ModelKeychain.write("")
                if ProcessInfo.processInfo.arguments.contains("--ui-test-paste-fixture") {
                    UIPasteboard.general.setObjects(
                        ["Pasted **text**." as NSString], localOnly: true, expirationDate: nil)
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-test-model-fixture") {
                    defaults.set("http://127.0.0.1:1/v1", forKey: "model.baseURL")
                    defaults.set("ui-test-model", forKey: "model.id")
                    try? ModelKeychain.write("ui-test-only-key")
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-test-agent-fixture") {
                    defaults.set("https://ui-fixture.markdownit.invalid/v1", forKey: "model.baseURL")
                    defaults.set("ui-test-model", forKey: "model.id")
                    modelClient = DebugModelFixture.client()
                    modelCatalog = DebugModelFixture.catalog()
                    try? ModelKeychain.write("ui-test-only-key")
                }
            }
        #endif
        _session = StateObject(
            wrappedValue: ReaderSession(defaults: defaults, modelClient: modelClient, modelCatalog: modelCatalog))
    }

    var body: some Scene {
        WindowGroup {
            ReaderScreen(session: session)
                .onOpenURL { url in Task { await session.open(url) } }
                .task {
                    #if DEBUG
                        let arguments = ProcessInfo.processInfo.arguments
                        if arguments.contains("--sample-document") {
                            await session.openSampleFixture(reset: arguments.contains("--reset-sample-document"))
                        }
                    #endif
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await session.flushChanges() } }
        }
    }
}
