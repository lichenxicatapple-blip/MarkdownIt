import OSLog
import SwiftUI
import WebKit

@MainActor
final class ReaderWKWebView: WKWebView {
    let workspace = ReaderWorkspace()
    var conversationPanel: ConversationPanel?
    var askSelectedText: (() -> Void)?
    var annotateSelectedText: ((String) -> Void)?
    var hasAnnotationSelection = false
    weak var sourceView: SourceTextView?
    weak var annotationView: UITextView?
    var findDocument: (() -> Void)?
    var inputBottomInset: CGFloat = 0 {
        didSet { if inputBottomInset != oldValue { inputBottomInsetDidChange?() } }
    }
    var inputBottomInsetDidChange: (() -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let sourceView, !sourceView.isHidden, sourceView.isUserInteractionEnabled,
            sourceView.alpha > 0.01, sourceView.bounds.contains(sourceView.convert(point, from: self))
        {
            return sourceView.hitTest(sourceView.convert(point, from: self), with: event)
        }
        return super.hitTest(point, with: event)
    }
    private var nativeInputFocused: Bool {
        sourceView?.isFirstResponder == true || annotationView?.isFirstResponder == true
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        if nativeInputFocused { return }
        let ask = UIAction(title: String(localized: "Reference in AI Chat…"), image: UIImage(systemName: "bubble.left"))
        {
            [weak self] _ in
            self?.askSelectedText?()
        }
        var actions: [UIMenuElement] = [ask]
        if hasAnnotationSelection {
            actions += [
                UIAction(title: String(localized: "Underline"), image: UIImage(systemName: "underline")) {
                    [weak self] _ in self?.annotateSelectedText?("underline")
                },
                UIAction(title: String(localized: "Add Annotation…"), image: UIImage(systemName: "text.bubble")) {
                    [weak self] _ in self?.annotateSelectedText?("note")
                },
            ]
        }
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: actions), atEndOfMenu: .standardEdit)
    }
}

@MainActor
final class ReaderBridge: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate,
    WKUIDelegate
{
    private static let lifecycleLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "MarkdownIt", category: "Reader")
    private let diagnosticID = UUID().uuidString.lowercased()
    let session: ReaderSession
    let webView: ReaderWKWebView
    let conversationWebView: WKWebView
    private let pasteboard: UIPasteboard
    private var readerReady = false
    private var conversationReady = false
    private(set) var ready = false
    private var loadedToken = ""
    private var lastTheme = ""
    private(set) var composer: NativeComposerHost!
    private(set) var conversationPanel: ConversationPanel!
    private(set) var imageMenu: ReaderImageMenu!
    private var actionMenu: ReaderActionMenu!
    private var pencil: ReaderPencilInteraction!
    private(set) var annotationHost: ReaderAnnotationHost!
    private(set) var documentFind: ReaderFindController!
    let sourceEditor = SourceEditor()
    private var sourceToken = ""
    private var projectedRevision = -1
    private var projectionTask: Task<Void, Error>?
    private var projectionGeneration = 0
    private var layoutTask: Task<Void, Never>?
    private var pendingLayout: [String: Any]?
    private var detached = false

    private static func configuration(for session: ReaderSession) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(session.resources, forURLScheme: "jm-resource")
        configuration.setURLSchemeHandler(session.agentImages, forURLScheme: "jm-image")
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let languages =
            (try? JSONSerialization.data(withJSONObject: Bundle.main.preferredLocalizations)) ?? Data("[]".utf8)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: "window.MarkdownItLanguages = \(String(decoding: languages, as: UTF8.self));",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        return configuration
    }

    init(session: ReaderSession, pasteboard: UIPasteboard = .general) {
        self.session = session
        self.pasteboard = pasteboard
        let configuration = Self.configuration(for: session)
        webView = ReaderWKWebView(frame: .zero, configuration: configuration)
        conversationWebView = WKWebView(frame: .zero, configuration: Self.configuration(for: session))
        super.init()
        documentFind = ReaderFindController(
            view: webView, source: sourceEditor.textView,
            preview: { [weak self] method, payload in try await self?.rawCall(method, payload: payload) },
            onVisibility: { [weak session] active in
                guard let session, session.findActive != active else { return }
                session.findActive = active
            })
        webView.findDocument = { [weak self] in Task { await self?.findInDocument() } }
        Self.lifecycleLog.notice("reader.created bridge=\(self.diagnosticID, privacy: .public)")
        if let document = session.document {
            sourceToken = session.documentToken
            sourceEditor.load(document.text)
            if let saved = session.restoredEditor {
                do { try sourceEditor.restore(saved) } catch {
                    session.errorMessage = String(
                        localized: "Unable to restore the editor: \(error.localizedDescription)")
                }
            }
        }
        // Source remains below its transparent Web selection/navigation surface;
        // the independent native conversation panel sits above both.
        webView.sourceView = sourceEditor.textView
        sourceEditor.onChange = { [weak self] id, status in self?.sourceDidChange(id: id, status: status) }
        sourceEditor.onCheckpoint = { [weak session] in session?.requestCheckpoint() }
        sourceEditor.onAsk = { [weak self] range in
            Task { try? await self?.askSourceSelection(range) }
        }
        actionMenu = ReaderActionMenu(webView: webView)
        imageMenu = ReaderImageMenu(menu: actionMenu)
        annotationHost = ReaderAnnotationHost(session: session, webView: webView, menu: actionMenu)
        pencil = ReaderPencilInteraction(webView: webView)
        pencil.enabled = { [weak self] in
            self?.session.mode == "preview" && self?.session.isClosingDocument == false
                && self?.annotationHost.hasUnsavedChanges == false
        }
        pencil.onBegin = { [weak self] in self?.annotationHost.dismiss() }
        pencil.send = { [weak self] payload in
            Task { _ = try? await self?.rawCall("annotationPencil", payload: payload) }
        }
        annotationHost.call = { [weak self] method, payload in
            _ = try? await self?.rawCall(method, payload: payload)
        }
        sourceEditor.history.onEdit = { [weak self] edit in
            guard let self else { return }
            self.session.annotationsEdited(
                edit, historyIDs: self.sourceEditor.history.transactionIDs)
        }
        imageMenu.onAsk = { [weak self] reference, token, point in
            guard let self, token == self.session.documentToken, self.session.mode == "preview",
                !self.session.isClosingDocument,
                let data = try? JSONEncoder().encode(reference),
                var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            payload["rect"] = ["left": point.x, "bottom": point.y]
            Task { _ = try? await self.call("askImage", arguments: ["payload": payload]) }
        }
        imageMenu.onDismiss = { [weak self] id in
            Task { _ = try? await self?.call("imageMenuDismissed", arguments: ["payload": ["id": id]]) }
        }
        composer = NativeComposerHost()
        composer.call = { [weak self] method, payload in
            _ = try? await self?.call(method, arguments: ["payload": payload])
        }
        composer.onCheckpoint = { [weak session] in session?.requestCheckpoint() }
        conversationPanel = ConversationPanel(webView: conversationWebView, composer: composer)
        webView.conversationPanel = conversationPanel
        conversationPanel.onClear = { [weak session] in
            guard let session else { return }
            session.requestAgentHistoryClear(token: session.documentToken)
        }
        conversationPanel.onCollapse = { [weak self] in self?.webView.workspace.request("agent", open: false) }
        conversationPanel.onSend = { [weak self] in
            Task { _ = try? await self?.call("sendAgentInput") }
        }
        conversationPanel.onInteraction = { [weak self] in self?.webView.workspace.interact("agent") }
        webView.workspace.onProjection = { [weak self] value in self?.projectLayout(value) }
        webView.workspace.onPresentation = { [weak session] open, visible, modal, leading in
            guard let session else { return }
            if session.documentLeading != leading { session.documentLeading = leading }
            if session.agentVisible != visible { session.agentVisible = visible }
            if session.agentOpen != open { session.agentOpen = open }
            if session.agentModalActive != modal { session.agentModalActive = modal }
        }
        conversationWebView.configuration.userContentController.add(self, name: "reader")
        conversationWebView.configuration.userContentController.addScriptMessageHandler(
            self, contentWorld: .page, name: "copyCode")
        conversationWebView.navigationDelegate = self
        conversationWebView.isOpaque = false
        conversationWebView.backgroundColor = .clear
        conversationWebView.scrollView.backgroundColor = .clear
        conversationWebView.scrollView.contentInsetAdjustmentBehavior = .never
        conversationWebView.scrollView.isScrollEnabled = false
        conversationWebView.accessibilityIdentifier = "ConversationWebView"
        configuration.userContentController.add(self, name: "reader")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "copyCode")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "conversation")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
        webView.accessibilityIdentifier = "ReaderWebView"
        #if DEBUG
            webView.isInspectable = true
        #endif
        webView.askSelectedText = { [weak self] in
            Task { _ = try? await self?.call("askSelection") }
        }
        webView.annotateSelectedText = { [weak self] action in
            Task { _ = try? await self?.call("annotationSelectionAction", arguments: ["payload": ["action": action]]) }
        }
        webView.inputBottomInsetDidChange = { [weak self] in self?.updateInputBottomInset() }
        session.bridge = self
        guard let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else {
            session.errorMessage = String(localized: "Offline rendering resources are missing.")
            return
        }
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        let conversationURL = index.deletingLastPathComponent().appendingPathComponent("conversation.html")
        conversationWebView.loadFileURL(conversationURL, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    func flushSource() -> String? {
        guard sourceToken == session.documentToken else { return session.document?.text }
        sourceEditor.commitInput()
        return sourceEditor.history.text
    }

    func applySourceEdit(before: String, after: String, id: String, changes: [SourceHistory.Edit.Delta]? = nil) -> Bool
    {
        guard sourceToken == session.documentToken, session.mode == "source" else { return false }
        return sourceEditor.replace(expected: before, with: after, id: id, changes: changes)
    }

    func moveSourceHistory(forward: Bool, id: String? = nil) -> Bool {
        guard sourceToken == session.documentToken, session.mode == "source" else { return false }
        sourceEditor.commitInput()
        return sourceEditor.history.move(forward: forward, id: id)
    }

    func call(_ method: String, arguments: [String: Any] = [:]) async throws -> Any? {
        if ["toggleMode", "toggleAgent", "askSelection", "askImage"].contains(method) { documentFind.dismiss() }
        if method == "toggleMode" {
            Self.lifecycleLog.notice(
                "reader.mode_switch bridge=\(self.diagnosticID, privacy: .public) document=\(self.session.documentToken, privacy: .public)"
            )
        }
        let payload = arguments["payload"]
        if ["toggleMode", "toggleAgent", "toggleOutline"].contains(method) {
            guard !annotationHost.hasUnsavedChanges else { return nil }
            await session.waitForAnnotations()
            annotationHost.dismiss()
        }
        switch method {
        case "askSelection" where session.mode == "source":
            try await askSourceSelection(sourceEditor.textView.selectedRange)
            return nil
        case "toggleMode", "toggleAgent", "commitAgentInput", "resolveAgentConsent":
            if method == "toggleMode" || method == "toggleAgent" { imageMenu.dismiss() }
            try await synchronizeProjection()
        case "diagnostics":
            startProjection()
            try await projectionTask?.value
        default: break
        }
        if method == "toggleMode", session.mode == "source" {
            let anchor = sourceEditor.capturePosition()
            sourceEditor.textView.resignFirstResponder()
            return try await rawCall(method, payload: ["anchor": anchor.payload])
        }
        if method == "scrollToSourceLine", session.mode == "source", let line = payload as? NSNumber {
            sourceEditor.restore(SourceReadingPosition(line: line.doubleValue, y: ReaderDesign.sourceTopInset))
            return try await call("diagnostics")
        }
        if method == "toggleOutline" {
            guard session.mode == "preview", session.hasOutline else { return nil }
            webView.workspace.request("outline", open: !webView.workspace.outline)
            await synchronizeLayout()
            return nil
        }
        if method == "toggleAgent" {
            if webView.workspace.agent {
                webView.workspace.request("agent", open: false)
                return nil
            }
            try await updateAgentBackground()
            return try await agentRawCall("openAgent")
        }
        if method == "agentInteraction" {
            webView.workspace.interact("agent")
            return nil
        }
        if method == "captureRecovery" {
            var value = try await rawCall(method) as? [String: Any] ?? [:]
            let conversation = try await agentRawCall(method) as? [String: Any] ?? [:]
            value.merge(conversation) { _, new in new }
            value.merge(webView.workspace.recovery) { _, new in new }
            return value
        }
        if method == "closeAgent" {
            webView.workspace.request("agent", open: false)
            return await webView.workspace.waitUntilClosed()
        }
        if [
            "resolveAgentEntry", "resolveAgentConsent", "updateAgentInput", "commitAgentInput",
            "sendAgentInput", "clearAgentHistory", "agentEvent", "agentUndoResult", "agentDiagnostics",
        ].contains(method) {
            if ["commitAgentInput", "sendAgentInput", "resolveAgentConsent"].contains(method) {
                try await updateAgentBackground()
            }
            return try await agentRawCall(method, payload: payload)
        }
        if method == "openDocument", let value = payload as? [String: Any] {
            webView.workspace.load(
                mode: value["mode"] as? String ?? session.mode, recovery: value["recovery"] as? [String: Any])
        }
        let result = try await rawCall(method, payload: payload)
        if method == "theme" { _ = try await agentRawCall(method, payload: payload) }
        if method == "openDocument", let value = payload as? [String: Any] {
            if let status = result as? [String: Any] {
                webView.workspace.update(
                    mode: status["mode"] as? String ?? session.mode,
                    hasOutline: !(status["headings"] as? [String] ?? []).isEmpty)
            }
            let background = try await rawCall("documentBackground") as? [String: Any] ?? [:]
            _ = try await agentRawCall(
                "openDocument",
                payload: [
                    "token": value["token"] ?? "", "name": value["name"] ?? "", "background": background,
                    "recovery": value["recovery"] ?? NSNull(), "conversation": value["conversation"] ?? NSNull(),
                ])
            await synchronizeLayout(refreshProjection: true)
            _ = try await rawCall("finishOpening")
        }
        if method == "diagnostics", var status = result as? [String: Any] {
            status["history"] = ["canUndo": sourceEditor.history.canUndo, "canRedo": sourceEditor.history.canRedo]
            status["source"] = sourceEditor.history.text
            if status["mode"] as? String == "source" { status["anchor"] = sourceEditor.capturePosition().payload }
            return status
        }
        return result
    }

    private func rawCall(_ method: String, payload: Any? = nil) async throws -> Any? {
        guard ready else { return nil }
        return try await webView.callAsyncJavaScript(
            "return await window.MarkdownIt[method](payload);",
            arguments: ["method": method, "payload": payload ?? NSNull()], in: nil, contentWorld: .page)
    }

    func findInDocument() async {
        guard ready, session.rendererReady, !session.isClosingDocument, !session.isOpeningDocument,
            !annotationHost.hasUnsavedChanges
        else { return }
        let token = session.documentToken
        do {
            try await synchronizeProjection()
            if webView.workspace.agent { _ = try await call("closeAgent") }
            guard token == session.documentToken, !detached, !session.isClosingDocument else { return }
            imageMenu.dismiss()
            annotationHost.dismiss()
            documentFind.present(source: session.mode == "source")
        } catch { session.errorMessage = error.localizedDescription }
    }

    private func projectLayout(_ value: [String: Any]) {
        guard ready else { return }
        pendingLayout = value
        guard layoutTask == nil else { return }
        layoutTask = Task { [weak self] in
            guard let self else { return }
            defer { self.layoutTask = nil }
            while let value = self.pendingLayout, !self.detached {
                self.pendingLayout = nil
                _ = try? await self.rawCall("panelLayout", payload: value)
                _ = try? await self.agentRawCall(
                    "presentation",
                    payload: [
                        "revision": value["revision"] ?? 0, "open": value["agent"] ?? false,
                        "modal": value["modal"] ?? false,
                    ])
            }
        }
    }

    private func synchronizeLayout(refreshProjection: Bool = false) async {
        webView.superview?.superview?.layoutIfNeeded()
        webView.superview?.layoutIfNeeded()
        if refreshProjection { webView.workspace.refreshProjection() }
        await layoutTask?.value
    }

    private func agentRawCall(_ method: String, payload: Any? = nil) async throws -> Any? {
        guard ready else { return nil }
        return try await conversationWebView.callAsyncJavaScript(
            "return await window.MarkdownIt[method](payload);",
            arguments: ["method": method, "payload": payload ?? NSNull()], in: nil, contentWorld: .page)
    }

    private func updateAgentBackground() async throws {
        guard var background = try await rawCall("documentBackground") as? [String: Any] else { return }
        background["mode"] = session.mode
        _ = try await agentRawCall("documentBackground", payload: background)
    }

    private func sourceDidChange(id: String?, status: String?) {
        guard sourceToken == session.documentToken else { return }
        session.sourceChanged(sourceEditor.history.text, token: sourceToken)
        documentFind.sourceChanged()
        session.sourceHistoryChanged(
            canUndo: sourceEditor.history.canUndo, canRedo: sourceEditor.history.canRedo, token: sourceToken)
        if let id, let status {
            let event = ["transactionID": id, "status": status]
            Task { _ = try? await self.agentRawCall("sourceHistory", payload: [event]) }
        }
        startProjection()
    }

    private func startProjection() {
        guard ready, sourceToken == loadedToken, projectionTask == nil else { return }
        let token = sourceToken
        let generation = projectionGeneration
        projectionTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == self.projectionGeneration { self.projectionTask = nil } }
            while !Task.isCancelled, generation == self.projectionGeneration,
                token == self.sourceToken && token == self.session.documentToken,
                self.projectedRevision != self.sourceEditor.history.revision
            {
                let revision = self.sourceEditor.history.revision
                let text = self.sourceEditor.history.text
                let accepted = try await self.rawCall(
                    "sourceState",
                    payload: [
                        "token": token, "text": text, "revision": revision,
                        "annotations": annotationRecords(),
                    ])
                guard generation == self.projectionGeneration, token == self.sourceToken, accepted as? Bool == true
                else { return }
                try await self.updateAgentBackground()
                self.projectedRevision = revision
            }
        }
    }

    private func synchronizeProjection() async throws {
        sourceEditor.commitInput()
        startProjection()
        try await projectionTask?.value
    }

    private func askSourceSelection(_ range: NSRange) async throws {
        guard session.mode == "source", range.length > 0 else { return }
        let token = sourceToken
        try await synchronizeProjection()
        guard token == sourceToken, token == session.documentToken,
            NSMaxRange(range) <= sourceEditor.history.text.utf16.count
        else { return }
        let view = sourceEditor.textView
        let position = view.position(from: view.beginningOfDocument, offset: NSMaxRange(range))
        let rect = position.map { view.convert(view.caretRect(for: $0), to: webView) } ?? .zero
        view.resignFirstResponder()
        _ = try await rawCall(
            "askSourceSelection",
            payload: [
                "start": range.location, "end": NSMaxRange(range),
                "rect": ["left": rect.minX, "right": rect.maxX, "top": rect.minY, "bottom": rect.maxY],
            ])
    }

    func update() {
        guard ready else { return }
        updateTheme()
        guard let document = session.document, loadedToken != session.documentToken else { return }
        documentFind.dismiss()
        imageMenu.dismiss()
        annotationHost.dismiss(force: true, animated: false)
        loadedToken = session.documentToken
        Self.lifecycleLog.notice(
            "reader.load bridge=\(self.diagnosticID, privacy: .public) document=\(self.loadedToken, privacy: .public)"
        )
        let token = loadedToken
        if sourceToken != token {
            projectionGeneration += 1
            projectionTask?.cancel()
            projectionTask = nil
            sourceToken = token
            sourceEditor.load(document.text)
            if let saved = session.restoredEditor {
                do { try sourceEditor.restore(saved) } catch {
                    session.errorMessage = String(
                        localized: "Unable to restore the editor: \(error.localizedDescription)")
                }
            }
        }
        projectedRevision = sourceEditor.history.revision
        Task {
            do {
                _ = try await call(
                    "openDocument",
                    arguments: [
                        "payload": [
                            "text": sourceEditor.history.text, "token": token,
                            "revision": sourceEditor.history.revision, "annotations": annotationRecords(),
                            "name": document.fileURL.lastPathComponent,
                            "mode": session.mode,
                            "recovery": session.webRecovery ?? NSNull() as Any,
                            "conversation": session.retainedConversation ?? NSNull() as Any,
                            "sourcePosition": sourceEditor.capturePosition().payload,
                        ]
                    ])
                guard token == session.documentToken else { return }
                session.rendererReady = true
                session.sourceHistoryChanged(
                    canUndo: sourceEditor.history.canUndo, canRedo: sourceEditor.history.canRedo, token: token)
                if session.consumeSourceFocusRequest() { sourceEditor.requestFocus() }
                if let saved = session.restoredComposer { composer.restore(saved) }
                session.requestCheckpoint()
                if token == session.documentToken, var saved = session.restoredAnnotation {
                    if let value = try await rawCall(
                        "resolveAnnotationAnchor",
                        payload: ["start": saved.request.anchor.start, "end": saved.request.anchor.end]),
                        let data = try? JSONSerialization.data(withJSONObject: value),
                        let rect = try? JSONDecoder().decode(AnnotationRequest.Rect.self, from: data)
                    {
                        saved.request.rect = rect
                        annotationHost.restore(saved)
                    }
                }
            } catch {
                session.errorMessage = String(
                    localized: "Unable to render this document: \(error.localizedDescription)")
            }
        }
    }

    func updateTheme() {
        let traits = webView.traitCollection
        let scale = UIFontMetrics(forTextStyle: .body).scaledValue(for: 16, compatibleWith: traits) / 16
        let names = [
            "chevron-right": "chevron.right", "chevron-down": "chevron.down", "quote": "quote.opening",
            "code": "chevron.left.forwardslash.chevron.right", "file-text": "doc.text", "x": "xmark",
            "arrow-up": "arrow.up", "square": "stop.fill",
            "message-square-text": "text.bubble",
            "copy": "doc.on.doc", "check": "checkmark",
        ]
        var symbols: [String: String] = [:]
        for (name, symbol) in names {
            if let image = UIImage(
                systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))?
                .withTintColor(.white, renderingMode: .alwaysOriginal), let data = image.pngData()
            {
                symbols[name] = "data:image/png;base64," + data.base64EncodedString()
            }
        }
        var palette: [String: String] = [:]
        for (name, color) in [
            "paper": UIColor.systemBackground, "chrome": .secondarySystemBackground, "ink": .label,
            "muted": .secondaryLabel, "line": .separator, "accent": webView.tintColor ?? .systemBlue,
        ] {
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            palette[name] = "rgba(\(r * 255),\(g * 255),\(b * 255),\(a))"
        }
        let fingerprint =
            "\(traits.userInterfaceStyle.rawValue)-\(traits.preferredContentSizeCategory.rawValue)-\(scale)"
        guard fingerprint != lastTheme else { return }
        lastTheme = fingerprint
        Task {
            _ = try? await call(
                "theme",
                arguments: ["payload": ["fontScale": scale, "symbols": symbols, "palette": palette]])
        }
    }

    private func annotationRecords() -> [[String: Any]] {
        session.annotations.visible.map { record in
            [
                "id": record.id.uuidString, "underlined": record.underlined, "hasNote": !record.note.isEmpty,
                "ranges": record.ranges.map { ["start": $0.start, "end": $0.end] },
            ]
        }
    }

    func projectAnnotations(acknowledging operation: String? = nil) async {
        _ = try? await rawCall(
            "annotationState",
            payload: [
                "token": session.documentToken,
                "revision": sourceEditor.history.revision, "records": annotationRecords(),
                "acknowledged": operation ?? NSNull() as Any,
            ])
    }

    private func updateInputBottomInset() {
        annotationHost.updateViewport()
        webView.superview?.setNeedsLayout()
        guard ready else { return }

    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
            let body = message.body as? [String: Any], let type = body["type"] as? String
        else { return }
        switch type {
        case "annotationRegions":
            guard body["token"] as? String == session.documentToken, let values = body["regions"],
                let data = try? JSONSerialization.data(withJSONObject: values),
                let regions = try? JSONDecoder().decode([ReaderPencilInteraction.Region].self, from: data)
            else { return }
            pencil.update(regions)
        case "annotationSelection":
            guard body["token"] as? String == session.documentToken else { return }
            let available = body["available"] as? Bool == true && session.mode == "preview"
            if webView.hasAnnotationSelection != available {
                webView.hasAnnotationSelection = available
                UIMenuSystem.context.setNeedsRebuild()
            }
            if available { annotationHost.dismiss() }
        case "annotationOpen":
            guard let value = body["request"], let data = try? JSONSerialization.data(withJSONObject: value),
                let request = try? JSONDecoder().decode(AnnotationRequest.self, from: data)
            else { return }
            annotationHost.show(request)
        case "annotationAction":
            guard body["token"] as? String == session.documentToken, body["action"] as? String == "underline",
                let values = body["ranges"], let data = try? JSONSerialization.data(withJSONObject: values),
                let ranges = try? JSONDecoder().decode([AnnotationRange].self, from: data),
                let revision = body["revision"] as? Int
            else { return }
            let token = session.documentToken
            let operation = body["operationID"] as? String
            let joining = Set((body["joining"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
            Task {
                let saved = await session.setAnnotation(
                    ranges: ranges, underlined: true, token: token, sourceRevision: revision, operationID: operation,
                    joining: joining)
                if !saved { await projectAnnotations(acknowledging: operation) }
            }
        case "annotationAnchor":
            guard body["token"] as? String == session.documentToken, let rect = body["rect"],
                let data = try? JSONSerialization.data(withJSONObject: rect),
                let rect = try? JSONDecoder().decode(AnnotationRequest.Rect.self, from: data)
            else { return }
            annotationHost.updateAnchor(rect)
        case "ready", "conversationReady":
            if type == "ready" {
                readerReady = true
            } else {
                conversationReady = true
                composer.beginPage()
            }
            ready = readerReady && conversationReady
            if ready {
                updateInputBottomInset()
                update()
            }
        case "recoveryChanged":
            if body["token"] as? String == session.documentToken { session.requestCheckpoint() }
        case "state":
            guard body["token"] as? String == session.documentToken else { return }
            if let mode = body["mode"] as? String, session.mode != mode { session.mode = mode }
            webView.workspace.update(mode: session.mode, hasOutline: body["hasOutline"] as? Bool == true)
            if let value = body["outline"] as? Bool, session.outlineExpanded != value {
                session.outlineExpanded = value
            }
            if let value = body["hasOutline"] as? Bool, session.hasOutline != value { session.hasOutline = value }
        case "documentReady": break
        case "imageMenu":
            guard body["token"] as? String == session.documentToken, session.mode == "preview",
                !session.agentModalActive, !session.isClosingDocument,
                let id = body["id"] as? String, let token = body["token"] as? String,
                let value = body["reference"], let data = try? JSONSerialization.data(withJSONObject: value),
                let reference = try? JSONDecoder().decode(AgentAttachment.self, from: data),
                let x = body["x"] as? Double, let y = body["y"] as? Double
            else { return }
            imageMenu.show(id: id, token: token, reference: reference, point: CGPoint(x: x, y: y))
        case "imageMenuDismiss":
            if body["token"] as? String == session.documentToken { imageMenu.dismiss() }
        case "localResources":
            if let paths = body["paths"] as? [String], let token = body["token"] as? String {
                session.localResourcesChanged(paths, token: token)
            }
        case "sourceLayout":
            guard body["token"] as? String == sourceToken else { return }
            guard let host = webView.hostNativeView(sourceEditor.textView, aboveWebContent: false) else { return }
            let frame = CGRect(
                x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0,
                width: body["width"] as? Double ?? 0, height: body["height"] as? Double ?? 0)
            sourceEditor.updateLayout(
                frame: webView.convert(frame, to: host),
                visible: body["visible"] as? Bool == true, opacity: body["opacity"] as? Double ?? 1,
                interactive: body["interactive"] as? Bool == true)
            documentFind.viewportChanged()
        case "sourceRestore":
            guard body["token"] as? String == sourceToken, let anchor = body["anchor"] as? [String: Any] else { return }
            sourceEditor.restore(SourceReadingPosition(anchor))
        case "panelRequest":
            guard body["token"] as? String == session.documentToken, let panel = body["panel"] as? String else {
                return
            }
            webView.workspace.request(
                panel,
                open: body["toggle"] as? Bool == true ? !webView.workspace.outline : body["open"] as? Bool == true)
        case "panelInteraction":
            if let panel = body["panel"] as? String { webView.workspace.interact(panel) }
        case "agentToggle":
            guard body["token"] as? String == session.documentToken else { return }
            webView.workspace.request("agent", open: body["open"] as? Bool == true)
        case "agentControls":
            guard body["token"] as? String == session.documentToken else { return }
            conversationPanel.updateControls(
                hasHistory: body["hasHistory"] as? Bool == true,
                generating: body["generating"] as? Bool == true, sendEnabled: body["sendEnabled"] as? Bool == true)
        case "agentEntry":
            if let id = body["id"] as? String, let token = body["token"] as? String {
                session.requestAgentEntry(id: id, token: token)
            }
        case "agentRequest":
            guard body["token"] as? String == session.documentToken, let id = body["id"] as? String,
                let intent = body["intent"] as? String, let snapshot = body["snapshot"],
                let data = try? JSONSerialization.data(withJSONObject: snapshot),
                let request = try? JSONDecoder().decode(AgentSnapshot.self, from: data)
            else { return }
            session.requestAgent(id: id, token: session.documentToken, snapshot: request, intent: intent)
        case "agentConsent":
            if let id = body["id"] as? String, let token = body["token"] as? String {
                session.requestDataSharingConsent(id: id, token: token)
            }
        case "agentCancel":
            if body["token"] as? String == session.documentToken {
                session.agentTransport.cancel(id: body["id"] as? String)
            }
        case "agentUndo":
            if let id = body["id"] as? String, let change = body["change"] as? String,
                let token = body["token"] as? String, token == session.documentToken
            {
                session.undoAgentChange(id: change, requestID: id, token: token)
            }
        case "agentLifecycle":
            guard body["token"] as? String == session.documentToken,
                let event = body["event"] as? String,
                ["user_clear", "document_reset", "restore_reset"].contains(event),
                let count = body["count"] as? Int, count >= 0
            else { return }
            Self.lifecycleLog.notice(
                "conversation.\(event, privacy: .public) bridge=\(self.diagnosticID, privacy: .public) turns=\(count, privacy: .public)"
            )
        case "inputSetText":
            guard body["token"] as? String == session.documentToken else { return }
            if let text = body["text"] as? String, let epoch = body["epoch"] as? Int {
                composer.setText(id: "question", text: text, epoch: epoch)
            }
        case "inputFocus":
            guard body["token"] as? String == session.documentToken else { return }
            composer.focus("question")
        case "inputBlur":
            guard body["token"] as? String == session.documentToken else { return }
            composer.blur()
        case "inputSubmit":
            guard body["token"] as? String == session.documentToken else { return }
            composer.submit("question")
        case "link":
            if let href = body["href"] as? String { Task { await session.resolveLink(href) } }
        default: break
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        if message.name == "copyCode" {
            guard message.webView === webView || message.webView === conversationWebView,
                message.frameInfo.isMainFrame, let value = message.body as? [String: Any],
                value["token"] as? String == session.documentToken, let text = value["text"] as? String
            else {
                replyHandler(false, nil)
                return
            }
            pasteboard.string = text
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
            replyHandler(true, nil)
            return
        }
        guard message.webView === webView, message.frameInfo.isMainFrame,
            let value = message.body as? [String: Any], value["token"] as? String == session.documentToken,
            let attachment = value["attachment"] as? [String: Any]
        else {
            replyHandler(false, nil)
            return
        }
        let token = session.documentToken
        Task {
            do {
                try await synchronizeProjection()
                guard token == session.documentToken else {
                    replyHandler(false, nil)
                    return
                }
                try await updateAgentBackground()
                _ = try await agentRawCall("attach", payload: attachment)
                replyHandler(true, nil)
            } catch { replyHandler(nil, error.localizedDescription) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy
    {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.isFileURL, let root = Bundle.main.resourceURL, url.path.hasPrefix(root.path + "/Web/") { return .allow }
        if url.scheme == "about" { return .allow }
        if navigationAction.navigationType == .linkActivated {
            await session.resolveLink(url.absoluteString)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, willPresentEditMenuWithAnimator animator: any UIEditMenuInteractionAnimating) {
        Task { _ = try? await call("suppressSelection") }
    }

    func webView(_ webView: WKWebView, contextMenuWillPresentForElement elementInfo: WKContextMenuElementInfo) {
        Task { _ = try? await call("suppressSelection") }
    }

    func detach() {
        guard !detached else { return }
        documentFind.dismiss()
        webView.findDocument = nil
        detached = true
        ready = false
        // Resigning native input can synchronously lay out the keyboard guides.
        // Stop presentation callbacks before tearing down their controls.
        webView.workspace.onChange = nil
        webView.workspace.onProjection = nil
        webView.workspace.onPresentation = nil
        Self.lifecycleLog.notice("reader.detached bridge=\(self.diagnosticID, privacy: .public)")
        if session.bridge === self {
            session.captureNativeRecovery()
            // Pending checkpoints must use the captured state after teardown.
            if session.rendererReady { session.rendererReady = false }
            session.finishDataSharingConsent(allowed: false)
            session.searchAuthorization.finish(allowed: false)
            session.agentTransport.cancel()
        }
        pencil.detach()
        annotationHost.detach()
        imageMenu.detach()
        actionMenu.detach()
        sourceEditor.history.onEdit = nil
        composer.detach()
        conversationPanel.removeFromSuperview()
        webView.conversationPanel = nil
        conversationWebView.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        conversationWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: "copyCode", contentWorld: .page)
        conversationWebView.navigationDelegate = nil
        conversationWebView.stopLoading()
        webView.askSelectedText = nil
        webView.annotateSelectedText = nil
        webView.inputBottomInsetDidChange = nil
        webView.sourceView = nil
        sourceEditor.detach()
        projectionGeneration += 1
        projectionTask?.cancel()
        projectionTask = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "copyCode", contentWorld: .page)
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "conversation", contentWorld: .page)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        session.errorMessage = String(localized: "Unable to load the reader: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let surface = webView === conversationWebView ? "conversation" : "document"
        Self.lifecycleLog.error(
            "reader.web_process_terminated surface=\(surface, privacy: .public) bridge=\(self.diagnosticID, privacy: .public) document=\(self.session.documentToken, privacy: .public)"
        )
        session.finishDataSharingConsent(allowed: false)
        session.searchAuthorization.finish(allowed: false)
        session.captureNativeRecovery()
        session.agentTransport.cancel()
        imageMenu.dismiss()
        composer.blur()
        conversationPanel.isHidden = true
        sourceEditor.textView.resignFirstResponder()
        sourceEditor.textView.isHidden = true
        projectionGeneration += 1
        projectionTask?.cancel()
        projectionTask = nil
        session.agentOpen = false
        session.agentVisible = false
        session.agentModalActive = false
        ready = false
        if webView === conversationWebView { conversationReady = false } else { readerReady = false }
        loadedToken = ""
        lastTheme = ""
        session.rendererReady = false
        webView.reload()
    }
}

struct ReaderWebView: UIViewRepresentable {
    @ObservedObject var session: ReaderSession
    @Environment(\.dynamicTypeSize) var dynamicType
    @Environment(\.colorScheme) var colorScheme

    func makeCoordinator() -> ReaderBridge { ReaderBridge(session: session) }
    func makeUIView(context: Context) -> ReaderContainer { ReaderContainer(webView: context.coordinator.webView) }
    func updateUIView(_ uiView: ReaderContainer, context: Context) { context.coordinator.update() }
    static func dismantleUIView(_ uiView: ReaderContainer, coordinator: ReaderBridge) { coordinator.detach() }
}
