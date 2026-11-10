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
        var webSearchClient = WebSearchClient()
        let modelSettings = ModelSettingsStore()
        var annotationStore = ReadingAnnotationStore()
        let conversationStore = AgentConversationStore(
            directory: AgentConversationStore.applicationDirectory(
                testing: ProcessInfo.processInfo.arguments.contains("--ui-testing")))
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                let annotationDirectory = ReadingAnnotationStore.applicationDirectory(testing: true)
                annotationStore = ReadingAnnotationStore(directory: annotationDirectory)
                if !ProcessInfo.processInfo.arguments.contains("--ui-test-keep-state"),
                    FileManager.default.fileExists(atPath: annotationDirectory.path)
                {
                    do { try FileManager.default.removeItem(at: annotationDirectory) } catch {
                        fatalError("Unable to reset isolated annotation test data: \(error)")
                    }
                }
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
                    webSearchClient = DebugModelFixture.searchClient()
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
                defaults: defaults, modelClient: modelClient, modelCatalog: modelCatalog,
                webSearchClient: webSearchClient,
                modelSettings: modelSettings,
                recoveryStore: ReaderRecoveryStore(
                    directory: ReaderRecoveryStore.applicationDirectory(
                        testing: ProcessInfo.processInfo.arguments.contains("--ui-testing"))),
                annotationStore: annotationStore, conversationStore: conversationStore))
    }

    var body: some Scene {
        WindowGroup {
            ReaderScreen(session: session)
                .onOpenURL { url in Task { await session.open(url) } }
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    #if DEBUG
                        if arguments.contains("--ui-testing") && !arguments.contains("--ui-test-keep-state") {
                            // The test App uses a separate conversation directory.
                            do { try await session.resetTestConversations() } catch {
                                fatalError("Unable to reset isolated conversation test data: \(error)")
                            }
                        }
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
