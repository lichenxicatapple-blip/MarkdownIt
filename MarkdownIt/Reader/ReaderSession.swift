import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
final class ReaderSession: ObservableObject {
    private var sourceFocusRequested = false

    @Published private(set) var document: MarkdownDocument?
    @Published private(set) var restoringSession = false
    @Published var recoveryConflict = false
    private let recoveryStore: ReaderRecoveryStore?
    private var recoverySequence: UInt64 = 0
    private var recoveryWeb: Data?
    private let conversationStore: AgentConversationStore?
    private var conversationWeb: Data?
    private var conversationOwner = UUID()
    private var conversationPath: String?
    private var conversationSequence: UInt64 = 0
    private var conversationRevision: UInt64 = 0
    private(set) var conversationID = UUID().uuidString.lowercased()
    private(set) var restoredAnnotation: ReaderAnnotationHost.Recovery?
    private(set) var restoredComposer: NativeComposerHost.Recovery?
    private(set) var restoredEditor: SourceEditor.Recovery?
    private var recoveryLocation: RecentDocument?
    private var pendingRecovery: ReaderRecovery?
    private var startupTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var checkpointRequested = false
    private var backgroundCheckpoint = false

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
    @Published var agentVisible = false
    @Published var agentModalActive = false
    @Published var documentLeading: CGFloat = 0
    @Published var needsModelConfiguration = false
    @Published var needsDataSharingConsent = false
    @Published var needsAgentHistoryClear = false
    private var agentHistoryClearToken: String?
    @Published var modelSettingsRequested = false
    @Published private(set) var isClosingDocument = false
    @Published var closeSaveFailed = false
    @Published var configuration = ModelConfiguration()
    @Published private(set) var modelSettingsError: String?
    weak var bridge: ReaderBridge?
    private(set) var annotations = ReadingAnnotations()
    private let annotationStore: ReadingAnnotationStore
    private var loadedAnnotations: ReadingAnnotations?
    private var annotationMutation: Task<Bool, Never>?
    private var annotationMutationID = UUID()
    private var annotationPath: String?
    private var annotationOwner = UUID()
    private var annotationRevision: UInt64 = 0
    private var annotationsSavedRevision: UInt64 = 0
    let resources = LocalResourceHandler()
    let agentImages = AgentImages()
    let searchAuthorization: WebSearchAuthorization
    private let webSearchClient: WebSearchClient
    @Published private(set) var searchSettings = WebSearchSettings()
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
    private let modelKey: (@MainActor () -> String)?
    private let modelSettings: ModelSettingsStore
    private var savedAPIKey = ""
    private var opening = false
    private var failedCloseToken: String?
    private var pendingAgentEntry: (id: String, token: String)?
    private var pendingDataSharing: (id: String, token: String, service: URL)?
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard, modelClient: ModelClient = ModelClient(),
        modelCatalog: ModelCatalog = ModelCatalog(),
        webSearchClient: WebSearchClient = WebSearchClient(),
        modelKey: (@MainActor () -> String)? = nil,
        modelSettings: ModelSettingsStore = ModelSettingsStore(),
        recoveryStore: ReaderRecoveryStore? = nil,
        annotationStore: ReadingAnnotationStore = ReadingAnnotationStore(),
        conversationStore: AgentConversationStore? = nil
    ) {
        self.defaults = defaults
        self.annotationStore = annotationStore
        self.recoveryStore = recoveryStore
        self.conversationStore = conversationStore
        restoringSession = recoveryStore != nil
        dataConsent = ModelDataConsent(defaults: defaults)
        searchAuthorization = WebSearchAuthorization(defaults: defaults)
        self.webSearchClient = webSearchClient
        recentDocuments = RecentDocumentsStore(defaults: defaults)
        self.modelKey = modelKey
        self.modelSettings = modelSettings
        agentTransport = AgentModelTransport(client: modelClient)
        self.modelCatalog = ModelCatalogCache { baseURL, key in
            try await modelCatalog.models(baseURL: baseURL, key: key)
        }
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
        agentTransport.checkpoint = { [weak self] in await self?.checkpointRecovery() }
        agentDocuments.checkpoint = { [weak self] in await self?.checkpointRecovery(includeWeb: false) }
        reloadModelSettings()
    }

    deinit {
        autosaveTask?.cancel()
        checkpointTask?.cancel()
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        documentScope?.stopAccessingSecurityScopedResource()
    }

    @discardableResult
    func grant(_ url: URL) async -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        var retained = false
        defer { if scoped && !retained { url.stopAccessingSecurityScopedResource() } }
        guard scoped || BookmarkedLocation.isAppOwned(url) else {
            if resourcePermissionDirectory != nil { needsResourcePermission = true }
            return false
        }
        if let directory = resourcePermissionDirectory, let document {
            let proposed = ResourceAccess(
                documentURL: document.fileURL, roots: [url], token: documentToken)
            guard proposed.containsDirectory(directory) else {
                needsResourcePermission = true
                return false
            }
        }
        if scoped {
            for previous in scopedURLs where previous == url { previous.stopAccessingSecurityScopedResource() }
            scopedURLs.removeAll { $0 == url }
            scopedURLs.append(url)
            retained = true
        }
        if !grantedRoots.contains(url) { grantedRoots.append(url) }
        resourcePermissionDirectory = nil
        needsResourcePermission = false
        configureResources()
        if let document { await recentDocuments.rememberFolders([url], for: document.fileURL) }
        requestCheckpoint()
        return true
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
                self.requestCheckpoint()
            }
        }
    }

    private func requestResourcePermissionIfReady() {
        // Resource requests and script messages arrive over separate WebKit
        // channels. Use document order to request concrete resource folders,
        // rather than whichever image happened to fail first.
        guard let document, let localResourcePaths, let deniedResourcePath else { return }
        self.deniedResourcePath = nil
        let access = ResourceAccess(documentURL: document.fileURL, roots: grantedRoots, token: documentToken)
        guard
            let directory = access.directoryRequiringAccess(for: localResourcePaths + [deniedResourcePath])
                ?? access.directoryContaining(deniedResourcePath)
        else { return }
        resourcePermissionDirectory = directory
        needsResourcePermission = true
    }

    func consumeSourceFocusRequest() -> Bool {
        defer { sourceFocusRequested = false }
        return sourceFocusRequested
    }

    func open(_ url: URL, startingNewDocument: Bool = false) async {
        await restoreLastSession()
        do {
            _ = try await openDocument(startingNewDocument: startingNewDocument) {
                RecentDocumentLocation(file: url, folders: await self.recentDocuments.folders(for: url))
            }
        } catch {
            errorMessage = String(localized: "Unable to open this document: \(error.localizedDescription)")
        }
    }

    func openRecent(_ recent: RecentDocument) async throws -> Bool {
        await restoreLastSession()
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
        replacing recentID: UUID? = nil, startingNewDocument: Bool = false,
        resolve: () async throws -> RecentDocumentLocation
    ) async throws -> Bool {
        guard !opening, !recoveryConflict, !isClosingDocument, failedCloseToken == nil,
            bridge?.annotationHost.hasUnsavedChanges != true
        else { return false }
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
        let nextAnnotationPath = ReadingAnnotationStore.path(for: url)
        let nextAnnotationOwner = UUID()
        let nextConversationPath = AgentConversationStore.path(for: url)
        let nextConversationOwner = UUID()
        let nextConversation = try await conversationStore?.load(
            path: nextConversationPath, owner: nextConversationOwner)
        var nextAnnotations = try await annotationStore.load(path: nextAnnotationPath, owner: nextAnnotationOwner)
        let rawAnnotations = nextAnnotations
        nextAnnotations.retireHistory()
        let next = MarkdownDocument(fileURL: url)
        guard await next.openForReading() else { throw CocoaError(.fileReadUnknown) }
        let access = ResourceAccess(documentURL: url, roots: grantedRoots, token: documentToken)
        let roots = await Task.detached(priority: .userInitiated) { access.rootsRequired(for: []) }.value
        let recent = await RecentDocumentsStore.prepare(url, folders: roots + restoredFolders, replacing: recentID)
        finishDataSharingConsent(allowed: false)
        searchAuthorization.finish(allowed: false)
        await agentTransport.stop()
        guard await preserveConversation() else {
            _ = await next.closeSavingChanges()
            return false
        }
        if let document, !(await document.closeSavingChanges()) {
            _ = await next.closeSavingChanges()
            errorMessage = String(localized: "The document could not be saved. Your changes have been kept.")
            return false
        }
        let previousToken = documentToken
        if document != nil { await endRecovery(token: previousToken) }
        recoveryWeb = nil
        conversationWeb = nil
        conversationRevision += 1
        conversationSequence = 0
        conversationOwner = nextConversationOwner
        conversationPath = nextConversationPath
        restoredEditor = nil
        restoredComposer = nil
        restoredAnnotation = nil
        recoverySequence = 0
        agentTransport.reset()
        agentImages.reset()
        finishDataSharingConsent(allowed: false)
        searchAuthorization.finish(allowed: false)
        agentDocuments.reset()
        failedCloseToken = nil
        closeSaveFailed = false
        pendingAgentEntry = nil
        finishAgentHistoryClear(confirmed: false)
        needsModelConfiguration = false
        agentOpen = false
        agentVisible = false
        agentModalActive = false
        documentLeading = 0
        documentToken = UUID().uuidString.lowercased()
        conversationID = nextConversation?.contextID ?? documentToken
        if let nextConversation {
            try agentTransport.restore(nextConversation.transport)
            agentDocuments.restore(nextConversation.tools)
            agentImages.restore(nextConversation.images, token: documentToken)
            conversationWeb = nextConversation.web
            if let composer = nextConversation.composer {
                restoredComposer = NativeComposerHost.Recovery(
                    text: composer.text, selection: composer.selection, focused: false, epoch: composer.epoch)
            }
        }
        localResourcePaths = nil
        deniedResourcePath = nil
        resourcePermissionDirectory = nil
        needsResourcePermission = false
        rendererReady = false
        mode = startingNewDocument ? "source" : "preview"
        sourceFocusRequested = startingNewDocument
        canUndoSource = false
        canRedoSource = false
        hasOutline = false
        documentScope?.stopAccessingSecurityScopedResource()
        documentScope = incomingScope
        scopedURLs.append(contentsOf: incomingFolderScopes)
        for folder in restoredFolders where !grantedRoots.contains(folder) { grantedRoots.append(folder) }
        recentDocuments.record(recent)
        recoveryLocation = recentDocuments.documents.first(where: { $0.identity == recent.identity }) ?? recent
        installed = true
        loadedAnnotations = rawAnnotations
        annotations = nextAnnotations
        annotationPath = nextAnnotationPath
        annotationOwner = nextAnnotationOwner
        annotationRevision = 0
        annotationsSavedRevision = 0
        document = next
        configureResources()
        pendingRecovery = nil
        if !startingNewDocument, !restoringSession, let recoveryLocation,
            let saved = try await recoveryStore?.load(location: recoveryLocation)
        {
            let validator = SourceHistory()
            try validator.restore(saved.editor.history)
            pendingRecovery = saved
            if next.persistedRevision != saved.savedRevision && next.text != saved.editor.history.text {
                recoveryConflict = true
            } else {
                try installRecovery(saved)
            }
        }
        requestCheckpoint()
        return true
    }

    func annotationsEdited(_ edit: SourceHistory.Edit, historyIDs: Set<String>) {
        guard document != nil, !annotations.records.isEmpty else { return }
        annotations.apply(edit)
        annotations.retainHistory(historyIDs)
        annotations.sourceRevision = nil
        annotationRevision += 1
        requestCheckpoint()
    }

    func setAnnotation(
        ranges: [AnnotationRange], underlined: Bool? = nil, note: String? = nil, id: UUID? = nil,
        token: String, sourceRevision: Int, operationID: String? = nil, joining: Set<UUID> = []
    ) async -> Bool {
        let previous = annotationMutation
        let mutationID = UUID()
        annotationMutationID = mutationID
        let task = Task { @MainActor in
            _ = await previous?.value
            return await self.commitAnnotation(
                ranges: ranges, underlined: underlined, note: note, id: id,
                token: token, sourceRevision: sourceRevision, operationID: operationID, joining: joining)
        }
        annotationMutation = task
        let result = await task.value
        if annotationMutationID == mutationID { annotationMutation = nil }
        return result
    }

    func waitForAnnotations() async { _ = await annotationMutation?.value }

    private func commitAnnotation(
        ranges: [AnnotationRange], underlined: Bool?, note: String?, id: UUID?, token: String, sourceRevision: Int,
        operationID: String?, joining: Set<UUID>
    ) async -> Bool {
        guard token == documentToken, mode == "preview", !isClosingDocument,
            let bridge, bridge.sourceEditor.history.revision == sourceRevision,
            let document, !ranges.isEmpty,
            ranges.allSatisfy({ $0.isValid && $0.end <= document.text.utf16.count })
        else { return false }
        do {
            var value = annotations
            if underlined == true && note == nil && id == nil {
                try value.addUnderline(
                    ranges: ranges, joining: joining, history: bridge.sourceEditor.history.snapshot())
            } else {
                try value.set(ranges: ranges, underlined: underlined, note: note, id: id)
            }
            value.sourceRevision = DocumentRevision.text(document.text)
            guard let path = annotationPath else { return false }
            let revision = annotationRevision + 1
            try await annotationStore.save(value, path: path, owner: annotationOwner, revision: revision)
            guard token == documentToken, bridge.sourceEditor.history.revision == sourceRevision else { return false }
            annotations = value
            annotationRevision = revision
            annotationsSavedRevision = revision
            await bridge.projectAnnotations(acknowledging: operationID)
            await checkpointRecovery(includeWeb: false)
            return true
        } catch {
            errorMessage = String(localized: "Unable to save annotations: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func saveAnnotations() async -> Bool {
        guard annotationRevision != annotationsSavedRevision, let path = annotationPath else { return true }
        let revision = annotationRevision
        let token = documentToken
        do {
            var snapshot = annotations
            snapshot.sourceRevision = document.map { DocumentRevision.text($0.text) }
            try await annotationStore.save(snapshot, path: path, owner: annotationOwner, revision: revision)
            if token == documentToken {
                annotationsSavedRevision = max(annotationsSavedRevision, revision)
                if annotationRevision == revision { annotations.sourceRevision = snapshot.sourceRevision }
            }
            return true
        } catch {
            errorMessage = String(localized: "Unable to save annotations: \(error.localizedDescription)")
            return false
        }
    }

    func sourceChanged(_ text: String, token: String) {
        guard token == documentToken, let document, text != document.text else { return }
        document.text = text
        document.updateChangeCount(.done)
        requestCheckpoint()
        scheduleAutosave()
    }

    private func scheduleAutosave() {
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
        let notesSaved = await saveAnnotations()
        await checkpointRecovery(includeWeb: false)
        if !saved, self.document === document, !isClosingDocument, failedCloseToken == nil {
            errorMessage = String(
                localized: "The document cannot be saved right now. Keep it open and check file access.")
        }
        return saved && notesSaved
    }

    private func synchronizeSource() {
        bridge?.webView.endEditing(true)
        _ = bridge?.flushSource()
    }

    @discardableResult
    func flushChanges() async -> Bool {
        guard !isClosingDocument, failedCloseToken == nil else { return false }
        await waitForAnnotations()
        synchronizeSource()
        autosaveTask?.cancel()
        guard await saveAnnotations() else { return false }
        return await saveCurrentDocument()
    }

    func cancelDocumentClose() {
        failedCloseToken = nil
        closeSaveFailed = false
    }

    func closeDocument(discardChanges: Bool = false) async {
        guard !opening, !isClosingDocument, let document else { return }
        guard bridge?.annotationHost.hasUnsavedChanges != true else { return }
        guard !discardChanges || failedCloseToken == documentToken else { return }
        isClosingDocument = true
        closeSaveFailed = false
        errorMessage = nil
        autosaveTask?.cancel()
        defer {
            isClosingDocument = false
            if self.document != nil { requestCheckpoint() }
        }
        await waitForAnnotations()
        if !discardChanges { synchronizeSource() }
        autosaveTask?.cancel()
        guard await saveAnnotations() else { return }
        finishDataSharingConsent(allowed: false)
        searchAuthorization.finish(allowed: false)
        await agentTransport.stop()
        guard await preserveConversation() else { return }
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
        await endRecovery(token: documentToken)
        recoveryWeb = nil
        conversationWeb = nil
        conversationPath = nil
        conversationRevision += 1
        restoredEditor = nil
        restoredComposer = nil
        restoredAnnotation = nil
        recoveryLocation = nil
        agentTransport.reset()
        agentImages.reset()
        finishDataSharingConsent(allowed: false)
        searchAuthorization.finish(allowed: false)
        agentDocuments.reset()
        pendingAgentEntry = nil
        finishAgentHistoryClear(confirmed: false)
        failedCloseToken = nil
        needsModelConfiguration = false
        needsResourcePermission = false
        localResourcePaths = nil
        deniedResourcePath = nil
        resourcePermissionDirectory = nil
        modelSettingsRequested = false
        agentOpen = false
        agentVisible = false
        agentModalActive = false
        documentLeading = 0
        documentToken = UUID().uuidString.lowercased()
        rendererReady = false
        mode = "preview"
        sourceFocusRequested = false
        canUndoSource = false
        canRedoSource = false
        outlineExpanded = false
        hasOutline = false
        resources.clear()
        documentScope?.stopAccessingSecurityScopedResource()
        documentScope = nil
        annotations = ReadingAnnotations()
        annotationPath = nil
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

    func requestAgentHistoryClear(token: String) {
        guard token == documentToken, document != nil, !isClosingDocument else { return }
        agentHistoryClearToken = token
        needsAgentHistoryClear = true
    }

    func finishAgentHistoryClear(confirmed: Bool) {
        let token = agentHistoryClearToken
        agentHistoryClearToken = nil
        if needsAgentHistoryClear { needsAgentHistoryClear = false }
        guard confirmed, let token, token == documentToken, document != nil, !isClosingDocument, let bridge else {
            return
        }
        conversationRevision += 1
        Task { [weak self, weak bridge] in
            guard let self, let bridge, token == self.documentToken else { return }
            await self.agentTransport.stop()
            self.agentTransport.reset()
            let retained = try? await bridge.call("clearAgentHistory", arguments: ["payload": ["token": token]])
            guard token == self.documentToken else { return }
            self.agentDocuments.reset()
            if let retained = retained as? [String] { self.agentImages.retain(Set(retained)) }
            await self.checkpointRecovery()
        }
    }

    var isModelConfigured: Bool {
        modelSettingsError == nil && (try? configuration.endpoint()) != nil
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var apiKey: String { modelKey?() ?? savedAPIKey }

    func requestAgentEntry(id: String, token: String) {
        guard token == documentToken else { return }
        if modelSettingsError != nil {
            reloadModelSettings()
            if let modelSettingsError {
                errorMessage = modelSettingsError
                return
            }
        }
        pendingAgentEntry = (id, token)
        if isModelConfigured { modelCatalog.prefetch(baseURL: configuration.baseURL, key: apiKey) }
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
        let key = apiKey
        let searchConfiguration = searchSettings
        let search =
            searchConfiguration.isConfigured
            ? AgentWebSearch(
                settings: searchConfiguration, client: webSearchClient,
                onResult: { [weak self] result in
                    guard let self, self.agentTransport.activeID == id else { return }
                    self.agentTransport.recordSearch(result, snapshot: snapshot)
                },
                onPage: { [weak self] page in
                    guard let self, self.agentTransport.activeID == id else { return }
                    self.agentTransport.recordWebPage(page, snapshot: snapshot)
                },
                authorize: { [weak self] provider in
                    guard let self else { return false }
                    return await self.searchAuthorization.authorize(provider: provider) { [weak self] in
                        guard let self else { return false }
                        return self.documentToken == token && !self.isClosingDocument
                            && self.agentTransport.activeID == id
                            && self.searchSettings.identity == searchConfiguration.identity
                    }
                }) : nil
        agentTransport.start(
            id: id, token: token, snapshot: snapshot, intent: intent, configuration: configuration, key: key,
            toolScope: searchConfiguration.identity, conversationID: conversationID,
            capabilities: { [weak self] in
                guard let self else { return ModelCapabilities() }
                return await self.modelCatalog.capabilities(configuration: configuration, key: key)
            },
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
            additionalTools: { [weak self] in
                guard let self, self.documentToken == token, self.document != nil, !self.isClosingDocument else {
                    return []
                }
                var tools = [AgentCurrentTime.definition]
                if self.agentImages.hasImages(in: snapshot) { tools.append(AgentImages.definition) }
                if search?.isAvailable == true && self.searchSettings.identity == searchConfiguration.identity {
                    tools += search?.definitions ?? []
                }
                return tools
            },
            readDocument: { [weak self] call, maxBytes in
                guard let self else { return AgentToolExecution(output: #"{"error":"document_closed"}"#) }
                return await self.agentDocuments.execute(call, token: token, maxReadBytes: maxBytes)
            },
            executeTool: { [weak self] call, maxReadBytes, onChange in
                guard let self, self.documentToken == token, self.document != nil, !self.isClosingDocument else {
                    return AgentToolExecution(output: #"{"error":"document_closed"}"#)
                }
                if call.name == AgentCurrentTime.definition.name { return AgentCurrentTime.execute(call) }
                if ["web_search", "read_webpage"].contains(call.name), let search {
                    guard self.searchSettings.identity == searchConfiguration.identity else {
                        return AgentToolExecution(output: #"{"error":"tool_unavailable"}"#)
                    }
                    return try await search.execute(call, maxReadBytes: maxReadBytes)
                }
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
                return await self.agentDocuments.execute(call, token: token, requestID: snapshot.id, onChange: onChange)
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

    func saveConfiguration(_ value: ModelConfiguration, key: String, search: WebSearchSettings? = nil) throws {
        try value.validateForSaving()
        let search = try (search ?? searchSettings).validated()
        try modelSettings.save(
            SavedModelSettings(configuration: value, apiKey: key, search: search.isEmpty ? nil : search),
            replacingLegacyIn: defaults)
        savedAPIKey = key
        searchSettings = search
        configuration = value
        modelSettingsError = nil
    }

    func resetModelSettings() throws {
        try modelSettings.reset(clearingLegacyIn: defaults)
        savedAPIKey = ""
        searchSettings = WebSearchSettings()
        searchAuthorization.finish(allowed: false)
        configuration = ModelConfiguration()
        modelSettingsError = nil
        modelCatalog.reset()
    }

    func reloadModelSettings() {
        do {
            let saved = try modelSettings.load(migrating: defaults)
            savedAPIKey = saved.apiKey
            searchSettings = saved.search ?? WebSearchSettings()
            configuration = saved.configuration
            modelSettingsError = nil
        } catch {
            modelSettingsError = String(localized: "Unable to read model settings.")
        }
    }

    #if DEBUG
        func resetTestConversations() async throws { try await conversationStore?.reset() }

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

extension ReaderSession {
    private func endRecovery(token: String) async {
        defaults.set(token, forKey: "reader.closedSession")
        do { try await recoveryStore?.remove(token: token) } catch {
            errorMessage = String(localized: "Unable to clear the saved reading session: \(error.localizedDescription)")
        }
    }

    func restoreLastSession(reset: Bool = false) async {
        if let startupTask {
            await startupTask.value
            return
        }
        guard let recoveryStore else {
            restoringSession = false
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.restoringSession = false }
            do {
                if reset {
                    try await recoveryStore.reset()
                    return
                }
                guard let record = try await recoveryStore.load() else { return }
                if self.defaults.string(forKey: "reader.closedSession") == record.token {
                    try await recoveryStore.remove(token: record.token)
                    return
                }
                // Validate the complete edit history before opening or dirtying a file.
                let validator = SourceHistory()
                try validator.restore(record.editor.history)
                self.recentDocuments.record(record.location)
                guard
                    try await self.openDocument(
                        replacing: record.location.id,
                        resolve: {
                            try await self.recentDocuments.resolve(record.location)
                        }), let document = self.document
                else { return }
                self.pendingRecovery = record
                if document.persistedRevision != record.savedRevision && document.text != record.editor.history.text {
                    self.recoveryConflict = true
                } else {
                    try self.installRecovery(record)
                }
            } catch {
                self.errorMessage = String(
                    localized: "Unable to restore the reading session: \(error.localizedDescription)")
            }
        }
        startupTask = task
        await task.value
    }

    private func installRecovery(_ record: ReaderRecovery) throws {
        guard let document else { return }
        if let snapshot = record.annotations {
            let stored = loadedAnnotations ?? annotations
            if stored.sourceRevision == DocumentRevision.text(record.editor.history.text) {
                annotations = stored
                annotations.restoreHistory(from: snapshot)
            } else {
                annotations = snapshot
            }
            annotationRevision += 1
        }
        loadedAnnotations = nil
        // The per-document conversation is authoritative, including a newer user clear.
        // Older open-reader checkpoints remain a migration source when it is absent.
        if conversationWeb == nil {
            try agentTransport.restore(record.transport)
            agentDocuments.restore(record.tools)
            agentImages.restore(record.images)
            restoredComposer = record.composer
            conversationID = record.conversationID ?? record.token
        } else {
            agentImages.restore(agentImages.checkpoint(), token: record.token)
            if let composer = restoredComposer {
                restoredComposer = NativeComposerHost.Recovery(
                    text: composer.text, selection: composer.selection,
                    focused: record.composer?.focused == true, epoch: composer.epoch)
            }
        }
        recoverySequence = record.sequence
        documentToken = record.token
        restoredEditor = record.editor
        restoredAnnotation = record.annotationDraft
        recoveryWeb = record.web
        if let conversationWeb,
            let retained = try JSONSerialization.jsonObject(with: conversationWeb) as? [String: Any]
        {
            var web: [String: Any] = [:]
            if let data = record.web { web = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] }
            web.merge(retained) { _, retained in retained }
            recoveryWeb = try JSONSerialization.data(withJSONObject: web)
        }
        if document.text != record.editor.history.text {
            document.text = record.editor.history.text
            document.updateChangeCount(.done)
            scheduleAutosave()
        }
        if let data = record.web,
            let web = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            mode = web["mode"] as? String == "source" ? "source" : "preview"
            outlineExpanded = web["outline"] as? Bool == true
        }
        pendingRecovery = nil
        configureResources()
        bridge?.update()
    }

    func resolveRecoveryConflict(useRecoveredChanges: Bool) {
        guard let record = pendingRecovery else { return }
        recoveryConflict = false
        do {
            if useRecoveredChanges {
                try installRecovery(record)
            } else {
                pendingRecovery = nil
                Task {
                    try? await recoveryStore?.remove(token: record.token)
                    requestCheckpoint()
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    var webRecovery: [String: Any]? {
        guard let recoveryWeb else { return nil }
        guard var web = try? JSONSerialization.jsonObject(with: recoveryWeb) as? [String: Any] else { return nil }
        if let restoredComposer, web["composerEpoch"] as? Int == restoredComposer.epoch,
            var conversation = web["conversation"] as? [String: Any]
        {
            conversation["draft"] = restoredComposer.text
            web["conversation"] = conversation
        }
        return web
    }

    var retainedConversation: [String: Any]? {
        guard recoveryWeb == nil, let conversationWeb else { return nil }
        return try? JSONSerialization.jsonObject(with: conversationWeb) as? [String: Any]
    }

    func requestCheckpoint() {
        guard recoveryStore != nil || conversationStore != nil,
            !restoringSession, pendingRecovery == nil, !isClosingDocument
        else { return }
        checkpointRequested = true
        guard checkpointTask == nil else { return }
        checkpointTask = Task { [weak self] in
            guard let self else { return }
            defer { self.checkpointTask = nil }
            while self.checkpointRequested && !Task.isCancelled {
                // Coalesce scroll, selection and streamed text. Lifecycle flushes
                // and native tool-effect journals bypass this IO cadence.
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                self.checkpointRequested = false
                await self.checkpointRecovery()
            }
        }
    }

    func checkpointRecovery(includeWeb: Bool = true) async {
        guard let document, !document.documentState.contains(.closed),
            let location = recoveryLocation,
            !restoringSession, !isClosingDocument, pendingRecovery == nil
        else { return }
        let token = documentToken
        guard await preserveConversation(includeWeb: includeWeb) else { return }
        guard token == documentToken, !isClosingDocument, pendingRecovery == nil else { return }
        guard let recoveryStore else { return }
        let editor: SourceEditor.Recovery
        if let bridge, bridge.sourceEditor.history.text == document.text {
            editor = bridge.sourceEditor.checkpoint()
        } else if let restoredEditor {
            editor = restoredEditor
        } else {
            let history = SourceHistory()
            history.reset(document.text)
            editor = SourceEditor.Recovery(
                history: history.snapshot(), selection: SourceSelection(range: NSRange(location: 0, length: 0)),
                position: SourceReadingPosition(line: 0, atStart: true), focused: false)
        }
        restoredEditor = editor
        let composer = rendererReady ? bridge?.composer.checkpoint() : restoredComposer
        restoredComposer = composer
        let annotationDraft = rendererReady ? bridge?.annotationHost.checkpoint() : restoredAnnotation
        restoredAnnotation = annotationDraft
        var annotationSnapshot = annotations
        if editor.history.text != document.text, let edit = editor.history.latestEdit {
            annotationSnapshot.apply(edit)
            annotationSnapshot.sourceRevision = DocumentRevision.text(editor.history.text)
        }
        recoverySequence += 1
        let record = ReaderRecovery(
            token: token, sequence: recoverySequence,
            location: recentDocuments.documents.first(where: { $0.id == location.id }) ?? location,
            savedRevision: document.persistedRevision, editor: editor,
            composer: composer, web: recoveryWeb,
            images: agentImages.checkpoint(), tools: agentDocuments.recovery(), transport: agentTransport.recovery(),
            annotations: annotationSnapshot, annotationDraft: annotationDraft, conversationID: conversationID)
        do { try await recoveryStore.save(record) } catch {
            if token == documentToken {
                errorMessage = String(
                    localized: "Unable to preserve the reading session: \(error.localizedDescription)")
            }
        }
    }

    /// Closing the reader ends auto-resume, but never deletes its conversation.
    @discardableResult
    private func preserveConversation(includeWeb: Bool = true) async -> Bool {
        guard document != nil else { return true }
        let token = documentToken
        let revision = conversationRevision
        do {
            if includeWeb, rendererReady, let bridge, bridge.ready {
                await bridge.composer.synchronize()
                let value = try await bridge.call("captureRecovery")
                guard token == documentToken, revision == conversationRevision else { return false }
                guard let value, JSONSerialization.isValidJSONObject(value) else {
                    throw CocoaError(.coderInvalidValue)
                }
                recoveryWeb = try JSONSerialization.data(withJSONObject: value)
            }
            guard token == documentToken, revision == conversationRevision else { return false }
            guard let conversationStore, let conversationPath,
                let data = recoveryWeb ?? conversationWeb,
                let web = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let conversation = web["conversation"]
            else { return true }
            // Reading layout and auto-resume belong exclusively to ReaderRecovery.
            let composer = rendererReady ? bridge?.composer.checkpoint() : restoredComposer
            var retainedConversation = conversation
            if let composer, web["composerEpoch"] as? Int == composer.epoch,
                var value = conversation as? [String: Any]
            {
                value["draft"] = composer.text
                retainedConversation = value
            }
            let retained = try JSONSerialization.data(withJSONObject: [
                "conversation": retainedConversation, "frozenImages": web["frozenImages"] ?? [],
                "composerEpoch": web["composerEpoch"] ?? 0,
            ])
            conversationSequence += 1
            try await conversationStore.save(
                AgentConversation(
                    contextID: conversationID, web: retained, images: agentImages.checkpoint(),
                    tools: agentDocuments.recovery(), transport: agentTransport.recovery(), composer: composer),
                path: conversationPath, owner: conversationOwner, sequence: conversationSequence)
            return true
        } catch {
            if token == documentToken {
                errorMessage = String(
                    localized: "Unable to preserve the AI conversation: \(error.localizedDescription)")
            }
            return false
        }
    }

    func captureNativeRecovery() {
        guard let bridge else { return }
        restoredEditor = bridge.sourceEditor.checkpoint()
        restoredComposer = bridge.composer.checkpoint()
        restoredAnnotation = bridge.annotationHost.checkpoint()
    }

    func checkpointForBackground() async {
        guard !backgroundCheckpoint else { return }
        backgroundCheckpoint = true
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "Preserve reading session")
        defer {
            backgroundCheckpoint = false
            if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
        }
        _ = bridge?.flushSource()
        await checkpointRecovery()
        _ = await saveCurrentDocument()
        await checkpointRecovery()
    }
}
