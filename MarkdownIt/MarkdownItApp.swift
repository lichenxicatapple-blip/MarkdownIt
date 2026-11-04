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
        let modelSettings = ModelSettingsStore()
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                let name = "dev.catli.MarkdownIt.ui-testing"
                defaults = UserDefaults(suiteName: name) ?? .standard
                if !ProcessInfo.processInfo.arguments.contains("--ui-test-keep-state") {
                    defaults.removePersistentDomain(forName: name)
                    try? modelSettings.reset(clearingLegacyIn: defaults)
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-test-paste-fixture") {
                    UIPasteboard.general.setObjects(
                        ["Pasted **text**." as NSString], localOnly: true, expirationDate: nil)
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-test-model-fixture") {
                    try? modelSettings.save(
                        SavedModelSettings(
                            configuration: ModelConfiguration(baseURL: "http://127.0.0.1:1/v1", model: "ui-test-model"),
                            apiKey: "ui-test-only-key"), replacingLegacyIn: defaults)
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-test-agent-fixture") {
                    modelClient = DebugModelFixture.client()
                    modelCatalog = DebugModelFixture.catalog()
                    try? modelSettings.save(
                        SavedModelSettings(
                            configuration: ModelConfiguration(
                                baseURL: "https://ui-fixture.markdownit.invalid/v1", model: "ui-test-model"),
                            apiKey: "ui-test-only-key"), replacingLegacyIn: defaults)
                }
            }
        #endif
        _session = StateObject(
            wrappedValue: ReaderSession(
                defaults: defaults, modelClient: modelClient, modelCatalog: modelCatalog, modelSettings: modelSettings,
                recoveryStore: ReaderRecoveryStore(
                    directory: ReaderRecoveryStore.applicationDirectory(
                        testing: ProcessInfo.processInfo.arguments.contains("--ui-testing")))))
    }

    var body: some Scene {
        WindowGroup {
            ReaderScreen(session: session)
                .onOpenURL { url in Task { await session.open(url) } }
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    #if DEBUG
                        await session.restoreLastSession(
                            reset: arguments.contains("--ui-testing") && !arguments.contains("--ui-test-keep-state"))
                    #else
                        await session.restoreLastSession()
                    #endif
                    #if DEBUG
                        if arguments.contains("--sample-document") {
                            await session.openSampleFixture(reset: arguments.contains("--reset-sample-document"))
                        }
                    #endif
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await session.checkpointForBackground() } }
        }
    }
}
