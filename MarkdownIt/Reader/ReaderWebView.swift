import SwiftUI
import WebKit

@MainActor
final class ReaderWKWebView: WKWebView {
    var askSelectedText: (() -> Void)?
    var annotateSelectedText: ((String) -> Void)?
    var hasAnnotationSelection = false
    weak var sourceView: SourceTextView?
    weak var annotationView: UITextView?
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
final class ReaderBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let session: ReaderSession
    let webView: ReaderWKWebView
    private(set) var ready = false
    private var loadedToken = ""
    private var lastTheme = ""
    private(set) var composer: NativeComposerHost!
    private(set) var imageMenu: ReaderImageMenu!
    private var actionMenu: ReaderActionMenu!
    private var pencil: ReaderPencilInteraction!
    private(set) var annotationHost: ReaderAnnotationHost!
    let sourceEditor = SourceEditor()
    private var sourceToken = ""
    private var projectedRevision = -1
    private var sourceEvents: [[String: String]] = []
    private var projectionTask: Task<Void, Error>?
    private var projectionGeneration = 0

    init(session: ReaderSession) {
        self.session = session
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
        webView = ReaderWKWebView(frame: .zero, configuration: configuration)
        super.init()
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
        // The transparent Web source surface lets its agent panel and scrim
        // composite above the native document without duplicating document text.
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
        composer = NativeComposerHost(webView: webView)
        composer.call = { [weak self] method, payload in
            _ = try? await self?.call(method, arguments: ["payload": payload])
        }
        composer.onCheckpoint = { [weak session] in session?.requestCheckpoint() }
        configuration.userContentController.add(self, name: "reader")
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
        let result = try await rawCall(method, payload: payload)
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

    private func sourceDidChange(id: String?, status: String?) {
        guard sourceToken == session.documentToken else { return }
        session.sourceChanged(sourceEditor.history.text, token: sourceToken)
        session.sourceHistoryChanged(
            canUndo: sourceEditor.history.canUndo, canRedo: sourceEditor.history.canRedo, token: sourceToken)
        if let id, let status {
            let event = ["transactionID": id, "status": status]
            if sourceEvents.last != event { sourceEvents.append(event) }
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
                let events = self.sourceEvents
                let text = self.sourceEditor.history.text
                let accepted = try await self.rawCall(
                    "sourceState",
                    payload: [
                        "token": token, "text": text, "events": events, "revision": revision,
                        "annotations": annotationRecords(),
                    ])
                guard generation == self.projectionGeneration, token == self.sourceToken, accepted as? Bool == true
                else { return }
                self.sourceEvents.removeFirst(min(events.count, self.sourceEvents.count))
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
        imageMenu.dismiss()
        annotationHost.dismiss(force: true, animated: false)
        loadedToken = session.documentToken
        let token = loadedToken
        if sourceToken != token {
            projectionGeneration += 1
            projectionTask?.cancel()
            projectionTask = nil
            sourceToken = token
            sourceEvents.removeAll()
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
                            "sourcePosition": sourceEditor.capturePosition().payload,
                        ]
                    ])
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
        for (name, symbol) in [
            "reader-chevron-right": "chevron.right", "reader-chevron-down": "chevron.down", "reader-trash-2": "trash",
        ] {
            if let data = ReaderChromeSymbols.image(symbol)?.pngData() {
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
        guard ready else { return }
        webView.callAsyncJavaScript(
            "window.MarkdownIt.setInputBottomInset(inset);",
            arguments: ["inset": webView.inputBottomInset], in: nil, in: .page,
            completionHandler: nil)
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
        case "ready":
            composer.beginPage()
            ready = true
            updateInputBottomInset()
            update()
        case "recoveryChanged":
            if body["token"] as? String == session.documentToken { session.requestCheckpoint() }
        case "state":
            guard body["token"] as? String == session.documentToken else { return }
            if let mode = body["mode"] as? String, session.mode != mode { session.mode = mode }
            if let value = body["outline"] as? Bool, session.outlineExpanded != value {
                session.outlineExpanded = value
            }
            if let value = body["hasOutline"] as? Bool, session.hasOutline != value { session.hasOutline = value }
        case "documentReady":
            if body["token"] as? String == session.documentToken {
                session.rendererReady = true
                if session.consumeSourceFocusRequest() { sourceEditor.requestFocus() }
                session.sourceHistoryChanged(
                    canUndo: sourceEditor.history.canUndo, canRedo: sourceEditor.history.canRedo,
                    token: session.documentToken)
                if let saved = session.restoredComposer { composer.restore(saved) }
                session.requestCheckpoint()
            }
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
            guard let host = webView.hostNativeInput(sourceEditor.textView, aboveWebContent: false) else { return }
            let frame = CGRect(
                x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0,
                width: body["width"] as? Double ?? 0, height: body["height"] as? Double ?? 0)
            sourceEditor.updateLayout(
                frame: webView.convert(frame, to: host),
                visible: body["visible"] as? Bool == true, opacity: body["opacity"] as? Double ?? 1,
                interactive: body["interactive"] as? Bool == true)
        case "sourceRestore":
            guard body["token"] as? String == sourceToken, let anchor = body["anchor"] as? [String: Any] else { return }
            sourceEditor.restore(SourceReadingPosition(anchor))
        case "agentPresentation":
            guard body["token"] as? String == session.documentToken else { return }
            let open = body["open"] as? Bool == true
            let visible = body["visible"] as? Bool == true
            let modal = body["modal"] as? Bool == true
            let leading = max(0, body["documentLeading"] as? Double ?? 0)
            if session.documentLeading != leading { session.documentLeading = leading }
            if session.agentVisible != visible { session.agentVisible = visible }
            if session.agentOpen != open { session.agentOpen = open }
            if session.agentModalActive != modal { session.agentModalActive = modal }
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
        case "agentClearHistory":
            if let token = body["token"] as? String {
                session.requestAgentHistoryClear(token: token)
            }
        case "agentUndo":
            if let id = body["id"] as? String, let change = body["change"] as? String,
                let token = body["token"] as? String, token == session.documentToken
            {
                session.undoAgentChange(id: change, requestID: id, token: token)
            }
        case "inputLayout":
            composer.updateLayout(body["inputs"] as? [[String: Any]] ?? [])
        case "inputSetText":
            if let id = body["id"] as? String, let text = body["text"] as? String, let epoch = body["epoch"] as? Int {
                composer.setText(id: id, text: text, epoch: epoch)
            }
        case "inputFocus":
            if let id = body["id"] as? String { composer.focus(id) }
        case "inputBlur": composer.blur()
        case "inputSubmit":
            if let id = body["id"] as? String { composer.submit(id) }
        case "link":
            if let href = body["href"] as? String { Task { await session.resolveLink(href) } }
        default: break
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
        session.finishDataSharingConsent(allowed: false)
        session.searchAuthorization.finish(allowed: false)
        session.agentTransport.reset()
        session.agentImages.reset()
        pencil.detach()
        annotationHost.detach()
        imageMenu.detach()
        actionMenu.detach()
        sourceEditor.history.onEdit = nil
        composer.detach()
        webView.askSelectedText = nil
        webView.annotateSelectedText = nil
        webView.inputBottomInsetDidChange = nil
        webView.sourceView = nil
        sourceEditor.detach()
        projectionGeneration += 1
        projectionTask?.cancel()
        projectionTask = nil
        sourceEvents.removeAll()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
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
        session.finishDataSharingConsent(allowed: false)
        session.searchAuthorization.finish(allowed: false)
        session.captureNativeRecovery()
        session.agentTransport.cancel()
        imageMenu.dismiss()
        composer.blur()
        sourceEditor.textView.resignFirstResponder()
        sourceEditor.textView.isHidden = true
        projectionGeneration += 1
        projectionTask?.cancel()
        projectionTask = nil
        session.agentOpen = false
        session.agentVisible = false
        session.agentModalActive = false
        ready = false
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
