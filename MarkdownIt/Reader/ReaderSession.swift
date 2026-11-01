import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
final class ReaderSession: ObservableObject {
    @Published private(set) var document: MarkdownDocument?
    @Published private(set) var documentToken = UUID().uuidString.lowercased()
    @Published var mode = "preview"
    @Published private(set) var canUndoSource = false
    @Published private(set) var canRedoSource = false
    @Published var outlineExpanded = false
    @Published var hasOutline = false
    @Published var rendererReady = false
    @Published var errorMessage: String?
    @Published var needsResourcePermission = false
    @Published private(set) var resourcePermissionDirectory: URL?
    @Published var agentOpen = false
    @Published var agentModalActive = false
    @Published var agentReservedWidth: CGFloat = 0
    @Published var documentLeading: CGFloat = 0
    @Published var needsModelConfiguration = false
    @Published var needsDataSharingConsent = false
    @Published var modelSettingsRequested = false
    @Published private(set) var isClosingDocument = false
    @Published var closeSaveFailed = false
    @Published var configuration: ModelConfiguration
    weak var bridge: ReaderBridge?
    let resources = LocalResourceHandler()
    let agentImages = AgentImages()
    private var grantedRoots: [URL] = []
    private var scopedURLs: [URL] = []
    private var documentScope: URL?
    private var localResourcePaths: [String]?
    private var deniedResourcePath: String?
    private var autosaveTask: Task<Void, Never>?
    let agentTransport: AgentModelTransport
    let modelCatalog: ModelCatalogCache
    let recentDocuments: RecentDocumentsStore
    let dataConsent: ModelDataConsent
    lazy var agentDocuments = AgentDocumentTools(session: self)
    private let modelKey: @MainActor () -> String
    private var opening = false
    private var failedCloseToken: String?
    private var pendingAgentEntry: (id: String, token: String)?
    private var pendingDataSharing: (id: String, token: String, service: URL)?
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard, modelClient: ModelClient = ModelClient(),
        modelCatalog: ModelCatalog = ModelCatalog(),
        modelKey: @escaping @MainActor () -> String = { ModelKeychain.read() }
    ) {
        self.defaults = defaults
        dataConsent = ModelDataConsent(defaults: defaults)
        recentDocuments = RecentDocumentsStore(defaults: defaults)
        self.modelKey = modelKey
        agentTransport = AgentModelTransport(client: modelClient)
        self.modelCatalog = ModelCatalogCache { baseURL, key in
            try await modelCatalog.models(baseURL: baseURL, key: key)
        }
        configuration = ModelConfiguration(
            baseURL: defaults.string(forKey: "model.baseURL") ?? "",
            model: defaults.string(forKey: "model.id") ?? "",
            apiProtocol: ModelAPIProtocol(rawValue: defaults.string(forKey: "model.apiProtocol") ?? "") ?? .responses)
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            grantedRoots.append(documents)
        }
        #if DEBUG
            if let sample = Bundle.main.resourceURL?.appendingPathComponent("Sample") { grantedRoots.append(sample) }
        #endif
        resources.onPermissionDenied = { [weak self] token, source in
            guard let self, token == self.documentToken else { return }
            self.deniedResourcePath = source
            self.requestResourcePermissionIfReady()
        }
    }

    deinit {
        autosaveTask?.cancel()
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        documentScope?.stopAccessingSecurityScopedResource()
    }

    func grant(_ url: URL) async {
        if !grantedRoots.contains(url) {
            if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
            grantedRoots.append(url)
        }
        configureResources()
        if let document { await recentDocuments.rememberFolders([url], for: document.fileURL) }
    }

    private func configureResources() {
        guard let document else { return }
        resources.configure(ResourceAccess(documentURL: document.fileURL, roots: grantedRoots, token: documentToken))
    }

    func localResourcesChanged(_ paths: [String], token: String) {
        guard token == documentToken else { return }
        let changed = localResourcePaths != paths
        localResourcePaths = paths
        requestResourcePermissionIfReady()
        if changed, let document {
            let file = document.fileURL
            let access = ResourceAccess(documentURL: file, roots: grantedRoots, token: token)
            Task { [recentDocuments] in
                let roots = await Task.detached(priority: .utility) { access.rootsRequired(for: paths) }.value
                await recentDocuments.rememberFolders(roots, for: file)
            }
        }
    }

    private func requestResourcePermissionIfReady() {
        // Resource requests and script messages arrive over separate WebKit
        // channels. Wait for the complete document inventory, even if a denied
        // image arrives first, so ../ references influence the initial folder.
        guard let document, let localResourcePaths, let deniedResourcePath else { return }
        self.deniedResourcePath = nil
        let access = ResourceAccess(documentURL: document.fileURL, roots: grantedRoots, token: documentToken)
        resourcePermissionDirectory =
            access.directoryRequiringAccess(for: localResourcePaths + [deniedResourcePath])
            ?? document.fileURL.deletingLastPathComponent()
        needsResourcePermission = true
    }

    func open(_ url: URL) async {
        do { _ = try await openDocument { RecentDocumentLocation(file: url, folders: []) } } catch {
            errorMessage = String(localized: "Unable to open this document: \(error.localizedDescription)")
        }
    }

    func openRecent(_ recent: RecentDocument) async throws -> Bool {
        do {
            return try await openDocument(replacing: recent.id) { try await self.recentDocuments.resolve(recent) }
        } catch {
            let value = error as NSError
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "MarkdownIt", category: "Documents")
                .error(
                    "Reopening a recent document failed: \(value.domain, privacy: .public) (\(value.code, privacy: .public))"
                )
            throw error
        }
    }

    private func openDocument(
        replacing recentID: UUID? = nil, resolve: () async throws -> RecentDocumentLocation
    ) async throws -> Bool {
        guard !opening, !isClosingDocument, failedCloseToken == nil else { return false }
        opening = true
        var incomingScope: URL?
        var incomingFolderScopes: [URL] = []
        var restoredFolders: [URL] = []
        var installed = false
        defer {
            opening = false
            if !installed {
                incomingScope?.stopAccessingSecurityScopedResource()
                for folder in incomingFolderScopes { folder.stopAccessingSecurityScopedResource() }
            }
        }
        let location = try await resolve()
        let url = location.file
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard MarkdownDocument.supportedFilenameExtensions.contains(url.pathExtension.lowercased()) else {
            throw CocoaError(
                .fileReadUnknown,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Only Markdown documents are supported.")])
        }
        if document?.fileURL.standardizedFileURL == url.standardizedFileURL { return true }
        for folder in location.folders {
            if grantedRoots.contains(folder) {
                restoredFolders.append(folder)
            } else if folder.startAccessingSecurityScopedResource() {
                incomingFolderScopes.append(folder)
                restoredFolders.append(folder)
            } else {
                // App-owned folders need no scope. A revoked external folder
                // must remain outside the image resolver's authorized roots.
                if BookmarkedLocation.isAppOwned(folder) { restoredFolders.append(folder) }
            }
        }
        if url.startAccessingSecurityScopedResource() { incomingScope = url }
        guard await flushChanges() else { return false }
        let next = MarkdownDocument(fileURL: url)
        guard await next.openForReading() else { throw CocoaError(.fileReadUnknown) }
        let access = ResourceAccess(documentURL: url, roots: grantedRoots, token: documentToken)
        let roots = await Task.detached(priority: .userInitiated) { access.rootsRequired(for: []) }.value
        let recent = await RecentDocumentsStore.prepare(url, folders: roots + restoredFolders, replacing: recentID)
        if let document, !(await document.closeSavingChanges()) {
            _ = await next.closeSavingChanges()
            errorMessage = String(localized: "The document could not be saved. Your changes have been kept.")
            return false
        }
        agentTransport.reset()
        agentImages.reset()
        finishDataSharingConsent(allowed: false)
        agentDocuments.reset()
        failedCloseToken = nil
        closeSaveFailed = false
        pendingAgentEntry = nil
        needsModelConfiguration = false
        agentOpen = false
        agentModalActive = false
        agentReservedWidth = 0
        documentLeading = 0
        documentToken = UUID().uuidString.lowercased()
        localResourcePaths = nil
        deniedResourcePath = nil
        resourcePermissionDirectory = nil
        needsResourcePermission = false
        rendererReady = false
        mode = "preview"
        canUndoSource = false
        canRedoSource = false
        hasOutline = false
        documentScope?.stopAccessingSecurityScopedResource()
        documentScope = incomingScope
        scopedURLs.append(contentsOf: incomingFolderScopes)
        for folder in restoredFolders where !grantedRoots.contains(folder) { grantedRoots.append(folder) }
        recentDocuments.record(recent)
        installed = true
        document = next
        configureResources()
        return true
    }

    func sourceChanged(_ text: String, token: String) {
        guard token == documentToken, let document, text != document.text else { return }
        document.text = text
        document.updateChangeCount(.done)
        autosaveTask?.cancel()
        guard !isClosingDocument, failedCloseToken == nil else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            _ = await self?.saveCurrentDocument()
        }
    }

    private func saveCurrentDocument() async -> Bool {
        guard !isClosingDocument, failedCloseToken == nil else { return false }
        guard let document, document.hasUnsavedChanges else { return true }
        let saved = await document.persist()
        if !saved, self.document === document, !isClosingDocument, failedCloseToken == nil {
            errorMessage = String(
                localized: "The document cannot be saved right now. Keep it open and check file access.")
        }
        return saved
    }

    private func synchronizeSource() {
        bridge?.webView.endEditing(true)
        _ = bridge?.flushSource()
    }

    @discardableResult
    func flushChanges() async -> Bool {
        guard !isClosingDocument, failedCloseToken == nil else { return false }
        synchronizeSource()
        autosaveTask?.cancel()
        return await saveCurrentDocument()
    }

    func cancelDocumentClose() {
        failedCloseToken = nil
        closeSaveFailed = false
    }

    func closeDocument(discardChanges: Bool = false) async {
        guard !opening, !isClosingDocument, let document else { return }
        guard !discardChanges || failedCloseToken == documentToken else { return }
        isClosingDocument = true
        closeSaveFailed = false
        errorMessage = nil
        autosaveTask?.cancel()
        defer { isClosingDocument = false }
        if !discardChanges { synchronizeSource() }
        autosaveTask?.cancel()
        let hadChanges = document.hasUnsavedChanges
        // UIDocument.close normally saves. Only an explicit discard choice
        // clears its dirty state so closing cannot retry the failed write.
        if discardChanges { document.updateChangeCount(.cleared) }
        guard await document.closeSavingChanges() else {
            if discardChanges && hadChanges { document.updateChangeCount(.done) }
            failedCloseToken = documentToken
            closeSaveFailed = true
            return
        }
        agentTransport.reset()
        agentImages.reset()
        finishDataSharingConsent(allowed: false)
        agentDocuments.reset()
        pendingAgentEntry = nil
        failedCloseToken = nil
        needsModelConfiguration = false
        needsResourcePermission = false
        localResourcePaths = nil
        deniedResourcePath = nil
        resourcePermissionDirectory = nil
        modelSettingsRequested = false
        agentOpen = false
        agentModalActive = false
        agentReservedWidth = 0
        documentLeading = 0
        documentToken = UUID().uuidString.lowercased()
        rendererReady = false
        mode = "preview"
        canUndoSource = false
        canRedoSource = false
        outlineExpanded = false
        hasOutline = false
        resources.clear()
        documentScope?.stopAccessingSecurityScopedResource()
        documentScope = nil
        self.document = nil
        bridge = nil
    }

    func toggleMode() {
        Task {
            await flushChanges()
            _ = try? await bridge?.call("toggleMode")
        }
    }

    func toggleOutline() {
        Task { _ = try? await bridge?.call("toggleOutline") }
    }

    func reloadResources() {
        configureResources()
        needsResourcePermission = false
        Task { _ = try? await bridge?.call("reloadResources") }
    }

    func resolveLink(_ href: String) async {
        if let url = URL(string: href), let scheme = url.scheme?.lowercased(),
            ["https", "http", "mailto"].contains(scheme)
        {
            await UIApplication.shared.open(url)
            return
        }
        guard let document else { return }
        do {
            let access = ResourceAccess(documentURL: document.fileURL, roots: grantedRoots, token: documentToken)
            let file = try access.resolve(href)
            guard MarkdownDocument.supportedFilenameExtensions.contains(file.pathExtension.lowercased()) else { return }
            await open(file)
        } catch {
            errorMessage = String(localized: "Allow access to the containing folder to open this linked document.")
        }
    }

    func toggleAgent() {
        Task { _ = try? await bridge?.call("toggleAgent") }
    }

    var isModelConfigured: Bool {
        (try? configuration.endpoint()) != nil && !modelKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func requestAgentEntry(id: String, token: String) {
        guard token == documentToken else { return }
        pendingAgentEntry = (id, token)
        if isModelConfigured { finishAgentConfiguration(saved: true) } else { needsModelConfiguration = true }
    }

    func finishAgentConfiguration(saved: Bool) {
        guard let entry = pendingAgentEntry else { return }
        pendingAgentEntry = nil
        let allowed = saved && isModelConfigured && entry.token == documentToken
        Task {
            _ = try? await bridge?.call(
                "resolveAgentEntry", arguments: ["payload": ["id": entry.id, "allowed": allowed]])
        }
    }

    @discardableResult
    func closeAgent() async -> Bool {
        (try? await bridge?.call("closeAgent")) as? Bool == true
    }

    var dataSharingServiceAddress: String { pendingDataSharing?.service.absoluteString ?? "" }

    func requestDataSharingConsent(id: String, token: String) {
        guard token == documentToken, document != nil, !isClosingDocument, pendingDataSharing == nil else {
            resolveDataSharingConsent(id: id, token: token, allowed: false)
            return
        }
        guard isModelConfigured, let service = try? ModelDataConsent.service(for: configuration) else {
            errorMessage = ModelError.configuration.localizedDescription
            resolveDataSharingConsent(id: id, token: token, allowed: false)
            return
        }
        if dataConsent.allows(service) {
            resolveDataSharingConsent(id: id, token: token, allowed: true)
        } else {
            pendingDataSharing = (id, token, service)
            needsDataSharingConsent = true
        }
    }

    func finishDataSharingConsent(allowed: Bool) {
        guard let pending = pendingDataSharing else { return }
        pendingDataSharing = nil
        needsDataSharingConsent = false
        let valid =
            allowed && document != nil && !isClosingDocument && pending.token == documentToken
            && (try? ModelDataConsent.service(for: configuration)) == pending.service && isModelConfigured
        if valid { dataConsent.allow(pending.service) }
        resolveDataSharingConsent(id: pending.id, token: pending.token, allowed: valid)
    }

    private func resolveDataSharingConsent(id: String, token: String, allowed: Bool) {
        Task { [weak bridge] in
            _ = try? await bridge?.call(
                "resolveAgentConsent", arguments: ["payload": ["id": id, "token": token, "allowed": allowed]])
        }
    }

    func requestAgent(id: String, token: String, snapshot: AgentSnapshot, intent: String) {
        guard token == documentToken, let bridge else { return }
        let emit: @MainActor (AgentModelEvent) async -> Void = { [weak bridge] event in
            guard let data = try? JSONEncoder().encode(event),
                let payload = try? JSONSerialization.jsonObject(with: data)
            else { return }
            _ = try? await bridge?.call("agentEvent", arguments: ["payload": payload])
        }
        // Recheck at the native transport boundary, including retries and any
        // connection change between approval and delivery of the Web snapshot.
        guard let service = try? ModelDataConsent.service(for: configuration), dataConsent.allows(service) else {
            Task {
                await emit(
                    AgentModelEvent(
                        id: id, token: token, type: "failed", failure: AgentFailure(ModelError.sharingPermission)))
            }
            return
        }
        let key = modelKey()
        agentTransport.start(
            id: id, token: token, snapshot: snapshot, intent: intent, configuration: configuration, key: key,
            contextWindow: modelCatalog.contextWindow(
                model: configuration.model, baseURL: configuration.baseURL, key: key),
            toolsAvailable: { [weak self] in
                self?.mode == "source" && self?.documentToken == token && self?.isClosingDocument == false
            },
            prepareImages: { [weak self] in
                guard let self, let document = self.document, self.documentToken == token else {
                    throw CancellationError()
                }
                let images = try await self.agentImages.prepare(
                    snapshot,
                    access: ResourceAccess(
                        documentURL: document.fileURL, roots: self.grantedRoots, token: token))
                await emit(AgentModelEvent(id: id, token: token, type: "images", imageIDs: self.agentImages.loadedIDs))
                return images
            },
            imageTools: { [weak self] in
                guard let self, self.documentToken == token, self.document != nil, !self.isClosingDocument,
                    self.agentImages.hasImages(in: snapshot)
                else { return [] }
                return [AgentImages.definition]
            },
            readDocument: { [weak self] call, maxBytes in
                guard let self else { return AgentToolExecution(output: #"{"error":"document_closed"}"#) }
                return await self.agentDocuments.execute(call, token: token, maxReadBytes: maxBytes)
            },
            executeTool: { [weak self] call, onChange in
                guard let self else { return AgentToolExecution(output: "{\"error\":\"document_closed\"}") }
                if call.name == "read_image", let document = self.document, self.documentToken == token,
                    !self.isClosingDocument
                {
                    let result = await self.agentImages.execute(
                        call,
                        access: ResourceAccess(
                            documentURL: document.fileURL, roots: self.grantedRoots, token: token))
                    await emit(
                        AgentModelEvent(id: id, token: token, type: "images", imageIDs: self.agentImages.loadedIDs))
                    return result
                }
                return await self.agentDocuments.execute(call, token: token, onChange: onChange)
            },
            emit: emit)
    }

    func undoAgentChange(id: String, requestID: String, token: String) {
        Task {
            let result = await agentDocuments.undo(id, token: token)
            guard documentToken == token else { return }
            _ = try? await bridge?.call("agentUndoResult", arguments: ["payload": ["id": requestID, "result": result]])
        }
    }

    func sourceHistoryChanged(canUndo: Bool, canRedo: Bool, token: String) {
        guard token == documentToken else { return }
        canUndoSource = canUndo
        canRedoSource = canRedo
    }

    func performSourceHistory(forward: Bool) {
        guard mode == "source", !isClosingDocument, document != nil else { return }
        _ = bridge?.moveSourceHistory(forward: forward)
    }

    func saveConfiguration(_ value: ModelConfiguration, key: String) throws {
        try value.validateForSaving()
        try ModelKeychain.write(key)
        configuration = value
        defaults.set(value.baseURL, forKey: "model.baseURL")
        defaults.set(value.model, forKey: "model.id")
        defaults.set(value.apiProtocol.rawValue, forKey: "model.apiProtocol")
    }

    #if DEBUG
        func openSampleFixture(reset: Bool = false) async {
            guard let source = Bundle.main.resourceURL?.appendingPathComponent("Sample"),
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return }
            let fixture = documents.appendingPathComponent("MarkdownIt-TestDocument", isDirectory: true)
            let failingSaves = ProcessInfo.processInfo.arguments.contains("--ui-test-save-failure")
            do {
                if reset && FileManager.default.fileExists(atPath: fixture.path) {
                    try FileManager.default.removeItem(at: fixture)
                }
                if !FileManager.default.fileExists(atPath: fixture.path) {
                    try FileManager.default.copyItem(at: source, to: fixture)
                }
                await grant(fixture)
                let filename = failingSaves ? "save-recovery.md" : "reading-guide.md"
                await open(fixture.appendingPathComponent(filename))
                if failingSaves {
                    document?.failNextWritesForTesting(.max)
                } else if ProcessInfo.processInfo.arguments.contains("--ui-test-save-failure-once") {
                    document?.failNextWritesForTesting(1)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    #endif
}
