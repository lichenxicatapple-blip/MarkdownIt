import UIKit
import XCTest

@testable import MarkdownIt

@MainActor
final class RecoveryTests: AgentReaderTestCase {
    private func store() throws -> ReaderRecoveryStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        return ReaderRecoveryStore(directory: root.appendingPathComponent("Recovery"))
    }

    private func reader(_ text: String, store: ReaderRecoveryStore) async throws -> (ReaderSession, ReaderBridge, URL) {
        let (session, bridge, _, url) = try await makeReader(
            text, baseURL: "https://recovery.example.invalid/v1",
            model: "fixture", modelClient: ModelClient(), modelKey: { "isolated-recovery-test-key" },
            recoveryStore: store,
            conversationStore: AgentConversationStore(
                directory: store.directory.deletingLastPathComponent().appendingPathComponent("Conversations")))
        return (session, bridge, url)
    }

    private func restored(_ store: ReaderRecoveryStore) async -> ReaderSession {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let session = ReaderSession(
            defaults: defaults, modelSettings: isolatedModelSettings(), recoveryStore: store,
            annotationStore: ReadingAnnotationStore(
                directory: store.directory.deletingLastPathComponent().appendingPathComponent("Annotations")),
            conversationStore: AgentConversationStore(
                directory: store.directory.deletingLastPathComponent().appendingPathComponent("Conversations")))
        addTeardownBlock { @MainActor in await session.closeDocument() }
        await session.restoreLastSession()
        return session
    }

    func testForegroundCheckpointPreservesUnconfirmedAIComposition() async throws {
        let store = try store()
        let original = "# Reading\n\nA passage to discuss.\n"
        let (session, bridge, _) = try await reader(original, store: store)
        _ = try await bridge.call("toggleAgent")
        try await wait {
            bridge.composer.view.window != nil
        }
        let input = try XCTUnwrap(
            bridge.composer.view)
        try await wait { input.isFirstResponder && !input.isHidden }
        for text in ["ni", "你好"] {
            input.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
            XCTAssertNotNil(input.markedTextRange)
            let selection = input.selectedRange
            await session.checkpointRecovery()
            XCTAssertNotNil(input.markedTextRange, "Saving the session must not confirm the user's IME candidates")
            XCTAssertEqual(input.text, text)
            XCTAssertEqual(input.selectedRange, selection)
            let loaded = try await store.load()
            let saved = try XCTUnwrap(loaded)
            XCTAssertEqual(saved.composer?.text, text)
            XCTAssertEqual(saved.editor.history.text, original)
            let web = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: XCTUnwrap(saved.web)) as? [String: Any])
            XCTAssertEqual((web["conversation"] as? [String: Any])?["draft"] as? String, text)
        }
        input.unmarkText()
        await session.checkpointRecovery()
        XCTAssertNil(input.markedTextRange)
        let loaded = try await store.load()
        XCTAssertEqual(try XCTUnwrap(loaded).composer?.text, "你好")
    }

    func testSourceCompositionCheckpointPreservesTextAndAnnotationPositionsTogether() async throws {
        let store = try store()
        let (session, bridge, _) = try await reader("word", store: store)
        let annotated = await session.setAnnotation(
            ranges: [.init(start: 0, end: 4)], underlined: true,
            token: session.documentToken, sourceRevision: bridge.sourceEditor.history.revision)
        XCTAssertTrue(annotated)
        try await sourceMode(bridge)
        let input = bridge.sourceEditor.textView
        input.selectedRange = NSRange(location: 0, length: 0)
        input.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        await session.checkpointRecovery()
        XCTAssertNotNil(input.markedTextRange)
        XCTAssertEqual(session.document?.text, "word")
        let loaded = try await store.load()
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.editor.history.text, "zhongword")
        XCTAssertEqual(saved.annotations?.visible.first?.ranges, [.init(start: 5, end: 9)])
        let restored = SourceHistory()
        try restored.restore(saved.editor.history)
        XCTAssertTrue(restored.move(forward: false))
        XCTAssertEqual(restored.text, "word")
        XCTAssertEqual(session.annotations.visible.first?.ranges, [.init(start: 0, end: 4)])
    }

    func testSourceCheckpointRestoresTextSelectionPositionAndBothHistoryStacks() async throws {
        let store = try store()
        let original = "# Reading\n\n" + (1...250).map { "Paragraph \($0). 👩🏽‍💻\n\n" }.joined()
        let (session, bridge, url) = try await reader(original, store: store)
        try await sourceMode(bridge)
        let editor = bridge.sourceEditor
        XCTAssertTrue(editor.replace(expected: original, with: original + "First edit.\n", id: "first"))
        XCTAssertTrue(
            editor.replace(expected: editor.history.text, with: editor.history.text + "Second edit.\n", id: "second"))
        XCTAssertTrue(editor.history.move(forward: false))
        let current = editor.history.text
        editor.restore(SourceReadingPosition(line: 180, y: 72))
        editor.textView.selectedRange = NSRange(location: 25, length: 9)
        let position = editor.capturePosition()
        await session.checkpointForBackground()
        let loaded = try await store.load()
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.editor.history.text, current)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), current)
        bridge.detach()
        session.agentTransport.cancel()
        _ = await session.document?.closeSavingChanges()
        let next = await restored(ReaderRecoveryStore(directory: store.directory))
        let (nextBridge, _) = try await mountReader(next)
        XCTAssertEqual(next.documentToken, saved.token)
        XCTAssertEqual(next.mode, "source")
        XCTAssertEqual(nextBridge.sourceEditor.history.text, current)
        XCTAssertEqual(nextBridge.sourceEditor.textView.selectedRange, NSRange(location: 25, length: 9))
        XCTAssertEqual(nextBridge.sourceEditor.capturePosition().line, position.line, accuracy: 0.1)
        XCTAssertTrue(next.canUndoSource)
        XCTAssertTrue(next.canRedoSource)
        XCTAssertTrue(nextBridge.moveSourceHistory(forward: true))
        XCTAssertEqual(nextBridge.sourceEditor.history.text, current + "Second edit.\n")
        XCTAssertTrue(nextBridge.moveSourceHistory(forward: false))
        XCTAssertTrue(nextBridge.moveSourceHistory(forward: false))
        XCTAssertEqual(nextBridge.sourceEditor.history.text, original)
        await next.closeDocument()
        let closed = await restored(ReaderRecoveryStore(directory: store.directory))
        XCTAssertNil(closed.document, "An explicit close must end the recoverable session")
    }

    func testPreviewCheckpointRestoresSemanticPositionReferenceAndNativeDraft() async throws {
        let store = try store()
        let text = (1...40).map { "## Section \($0)\n\n" + String(repeating: "Paragraph content.\n\n", count: 12) }
            .joined()
        let (session, bridge, _) = try await reader(text, store: store)
        _ = try await bridge.call("scrollToSourceLine", arguments: ["payload": 230])
        _ = try await bridge.call("askSelection", arguments: ["payload": "A quoted paragraph."])
        try await wait { session.agentOpen }
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "document.querySelector('.mdv-composer textarea').value = 'Unsent draft 👩🏽‍💻';")
        try await wait { bridge.composer.checkpoint()?.text == "Unsent draft 👩🏽‍💻" }
        await session.checkpointForBackground()
        let loaded = try await store.load()
        let saved = try XCTUnwrap(loaded)
        let web = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(saved.web)) as? [String: Any])
        let before = try XCTUnwrap(web["anchor"] as? [String: Any])
        bridge.detach()
        _ = await session.document?.closeSavingChanges()
        let next = await restored(ReaderRecoveryStore(directory: store.directory))
        let (nextBridge, _) = try await mountReader(next)
        try await wait { next.agentOpen && nextBridge.composer.checkpoint()?.text == "Unsent draft 👩🏽‍💻" }
        let inert =
            try await nextBridge.conversationWebView.evaluateJavaScript(
                "document.querySelector('.mdv-agent').inert") as? Bool
        XCTAssertEqual(inert, false, "Restoring an open panel must restore interaction and accessibility")
        let captured = try await nextBridge.call("captureRecovery")
        let value = try XCTUnwrap(captured as? [String: Any])
        let after = try XCTUnwrap(value["anchor"] as? [String: Any])
        XCTAssertEqual(after["line"] as? Double ?? -1, before["line"] as? Double ?? -2, accuracy: 0.15)
        let conversation = try XCTUnwrap(value["conversation"] as? [String: Any])
        let attachment = try XCTUnwrap(conversation["attachment"] as? [String: Any])
        XCTAssertEqual(attachment["text"] as? String, "A quoted paragraph.")
        XCTAssertEqual(conversation["draft"] as? String, "Unsent draft 👩🏽‍💻")
    }

    func testExternalChangesRequireAChoiceBeforeRecoveringEdits() async throws {
        for useRecovered in [false, true] {
            let store = try store()
            let (session, bridge, url) = try await reader("# Original\n", store: store)
            try await sourceMode(bridge)
            XCTAssertTrue(bridge.sourceEditor.replace(expected: "# Original\n", with: "# Recovered\n"))
            await session.checkpointForBackground()
            bridge.detach()
            _ = await session.document?.closeSavingChanges()
            try Data("# External edit\n".utf8).write(to: url, options: .atomic)
            let next = await restored(ReaderRecoveryStore(directory: store.directory))
            XCTAssertTrue(next.recoveryConflict)
            XCTAssertEqual(next.document?.text, "# External edit\n")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# External edit\n")
            next.resolveRecoveryConflict(useRecoveredChanges: useRecovered)
            XCTAssertEqual(next.document?.text, useRecovered ? "# Recovered\n" : "# External edit\n")
            XCTAssertEqual(
                try String(contentsOf: url, encoding: .utf8), "# External edit\n",
                "Choosing a version does not write before normal saving")
        }
    }

    func testCompletedToolReceiptSurvivesRestartWithoutApplyingTheEditTwice() async throws {
        let store = try store()
        let (session, bridge, _) = try await reader("# Original\n", store: store)
        try await sourceMode(bridge)
        let data = try JSONSerialization.data(withJSONObject: [
            "revision": AgentDocumentTools.revision("# Original\n"),
            "edits": [["before": "Original", "after": "Edited"]],
        ])
        let call = ModelToolCall(
            id: "durable-edit", name: "edit_document", arguments: String(decoding: data, as: UTF8.self))
        let first = await session.agentDocuments.execute(
            call, token: session.documentToken, requestID: "immutable-request")
        XCTAssertEqual(bridge.sourceEditor.history.text, "# Edited\n")
        await session.checkpointForBackground()
        bridge.detach()
        _ = await session.document?.closeSavingChanges()
        let next = await restored(ReaderRecoveryStore(directory: store.directory))
        let (nextBridge, _) = try await mountReader(next)
        let revision = nextBridge.sourceEditor.history.revision
        let replay = await next.agentDocuments.execute(call, token: next.documentToken, requestID: "immutable-request")
        XCTAssertEqual(replay.output, first.output)
        XCTAssertEqual(replay.change?.id, first.change?.id)
        XCTAssertEqual(nextBridge.sourceEditor.history.revision, revision)
        let result = await next.agentDocuments.undo(try XCTUnwrap(first.change?.id), token: next.documentToken)
        XCTAssertEqual(result["status"], "undone")
        XCTAssertEqual(nextBridge.sourceEditor.history.text, "# Original\n")
    }

    func testFrozenImagePixelsRestoreEvenWhenTheOriginalImageChanges() async throws {
        let store = try store()
        let (session, bridge, url) = try await reader("# Images\n\n![Chart](chart.png)\n", store: store)
        let imageURL = url.deletingLastPathComponent().appendingPathComponent("chart.png")
        func image(_ color: UIColor) throws -> Data {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
            return try XCTUnwrap(
                renderer.image { context in
                    color.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
                }.pngData())
        }
        try image(.red).write(to: imageURL)
        let reference = AgentImageReference(id: UUID().uuidString, source: "chart.png", alt: "Chart")
        let attachment = AgentAttachment(
            text: "Chart", markdown: "![Chart](chart.png)", mode: "preview",
            scope: "selection", location: nil, start: nil, end: nil, images: [reference])
        let snapshot = AgentSnapshot(question: "Explain", attachment: attachment, history: [])
        let first = try await session.agentImages.prepare(
            snapshot,
            access: ResourceAccess(
                documentURL: url, roots: [url.deletingLastPathComponent()], token: session.documentToken))
        await session.checkpointForBackground()
        bridge.detach()
        _ = await session.document?.closeSavingChanges()
        try image(.blue).write(to: imageURL)
        let next = await restored(ReaderRecoveryStore(directory: store.directory))
        let recovered = try await next.agentImages.prepare(
            snapshot,
            access: ResourceAccess(
                documentURL: url, roots: [url.deletingLastPathComponent()], token: next.documentToken))
        XCTAssertEqual(recovered, first, "Sent image IDs must retain their original pixels across process death")
        await next.closeDocument()
        await next.open(url)
        XCTAssertNotEqual(next.documentToken, session.documentToken)
        let reopened = try await next.agentImages.prepare(
            snapshot,
            access: ResourceAccess(
                documentURL: url, roots: [url.deletingLastPathComponent()], token: next.documentToken))
        XCTAssertEqual(reopened, first, "Reopening a conversation must not reload changed image pixels")
    }

    func testInaccessibleDocumentDraftSurvivesOpeningAnotherFile() async throws {
        let store = try store()
        let (session, bridge, url) = try await reader("# Original\n", store: store)
        try await sourceMode(bridge)
        XCTAssertTrue(bridge.sourceEditor.replace(expected: "# Original\n", with: "# Recover this draft\n"))
        await session.checkpointForBackground()
        let loaded = try await store.load()
        let record = try XCTUnwrap(loaded)
        bridge.detach()
        _ = await session.document?.closeSavingChanges()
        let moved = url.appendingPathExtension("unavailable")
        try FileManager.default.moveItem(at: url, to: moved)
        let next = await restored(ReaderRecoveryStore(directory: store.directory))
        XCTAssertNil(next.document)
        XCTAssertNotNil(next.errorMessage)
        next.errorMessage = nil  // Acknowledge the restore failure before opening another document.
        let other = url.deletingLastPathComponent().appendingPathComponent("other.md")
        try Data("# Other\n".utf8).write(to: other)
        await next.open(other)
        let (otherBridge, _) = try await mountReader(next)
        XCTAssertEqual(otherBridge.sourceEditor.history.text, "# Other\n")
        await next.checkpointForBackground()
        let retained = try await store.load(location: record.location)
        XCTAssertEqual(retained?.editor.history.text, "# Recover this draft\n")
        try FileManager.default.moveItem(at: moved, to: url)
        await next.open(url)
        XCTAssertEqual(next.document?.text, "# Recover this draft\n")
        XCTAssertEqual(next.documentToken, record.token)
    }

    func testFailedSaveStillRestoresTheWorkingTextAndOriginalFileFormat() async throws {
        let store = try store()
        let (session, bridge, url) = try await reader("# Original\n", store: store)
        // Reload a real BOM/CRLF file, so recovery must retain its native document format.
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("# Original\r\n".utf8)
        try session.document?.load(fromContents: original, ofType: nil)
        try original.write(to: url)
        try await sourceMode(bridge)
        session.document?.failNextWritesForTesting(1)
        XCTAssertTrue(bridge.sourceEditor.replace(expected: "# Original\n", with: "# Unsaved 👩🏽‍💻\n"))
        let saved = await session.flushChanges()
        XCTAssertFalse(saved)
        XCTAssertEqual(try Data(contentsOf: url), original)
        await session.checkpointRecovery()
        bridge.detach()
        session.document?.updateChangeCount(.cleared)
        _ = await session.document?.closeSavingChanges()
        let next = await restored(ReaderRecoveryStore(directory: store.directory))
        let (nextBridge, _) = try await mountReader(next)
        XCTAssertEqual(nextBridge.sourceEditor.history.text, "# Unsaved 👩🏽‍💻\n")
        XCTAssertTrue(nextBridge.sourceEditor.history.canUndo)
        let persisted = await next.flushChanges()
        XCTAssertTrue(persisted)
        XCTAssertEqual(try Data(contentsOf: url), Data([0xEF, 0xBB, 0xBF]) + Data("# Unsaved 👩🏽‍💻\r\n".utf8))
    }

    func testRendererReloadKeepsTheNativeSessionAndDraft() async throws {
        let store = try store()
        let (session, bridge, _) = try await reader("# Reading\n\nContent.\n", store: store)
        _ = try await bridge.call("askSelection", arguments: ["payload": "Content."])
        try await wait { session.agentOpen }
        _ = try await bridge.conversationWebView.evaluateJavaScript(
            "const field = document.querySelector('.mdv-composer textarea'); for (let i = 0; i < 5; ++i) field.value = 'Draft ' + i; field.value = 'Keep this draft';"
        )
        try await wait { bridge.composer.checkpoint()?.text == "Keep this draft" }
        await session.checkpointRecovery()
        let token = session.documentToken
        bridge.webViewWebContentProcessDidTerminate(bridge.webView)
        try await wait { session.rendererReady && bridge.ready && session.agentOpen }
        let value = try await state(bridge)
        XCTAssertEqual(value["draft"] as? String, "Keep this draft")
        XCTAssertTrue((value["reference"] as? String)?.contains("Content.") == true)
        XCTAssertEqual(session.documentToken, token)
        let native = try XCTUnwrap(bridge.composer.checkpoint())
        bridge.composer.setText(id: "question", text: "New draft after reload", epoch: native.epoch)
        await bridge.composer.synchronize()
        let updated = try await state(bridge)
        XCTAssertEqual(
            updated["draft"] as? String, "New draft after reload",
            "Native input must still synchronize after a fresh Web page resets its epochs")
    }

    func testNewerWebDraftCannotBeReplacedByAStaleNativeInputSnapshot() async throws {
        let store = try store()
        let (session, bridge, _) = try await reader("# Drafts\n", store: store)
        _ = try await bridge.call("toggleAgent")
        try await wait { session.agentOpen }
        await session.checkpointRecovery()
        let loaded = try await store.load()
        let record = try XCTUnwrap(loaded)
        var web = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(record.web)) as? [String: Any])
        let current = try XCTUnwrap(record.composer)
        // The Web has cleared a sent question, while its native set-text message
        // is still queued. The same epoch check used for live input must apply on recovery.
        web["composerEpoch"] = current.epoch + 1
        var conversation = try XCTUnwrap(web["conversation"] as? [String: Any])
        conversation["draft"] = ""
        web["conversation"] = conversation
        let stale = NativeComposerHost.Recovery(
            text: "Already sent", selection: NSRange(location: 12, length: 0),
            focused: false, epoch: current.epoch)
        let checkpoint = ReaderRecovery(
            token: record.token, sequence: record.sequence + 1, location: record.location,
            savedRevision: record.savedRevision, editor: record.editor, composer: stale,
            web: try JSONSerialization.data(withJSONObject: web), images: record.images, tools: record.tools,
            transport: record.transport)
        try await store.save(checkpoint)
        bridge.detach()
        _ = await session.document?.closeSavingChanges()
        let next = await restored(ReaderRecoveryStore(directory: store.directory))
        let restoredWeb = try XCTUnwrap(next.webRecovery)
        let restoredConversation = try XCTUnwrap(restoredWeb["conversation"] as? [String: Any])
        XCTAssertEqual(
            restoredConversation["draft"] as? String, "",
            "An older native field must not resurrect an already-sent question")
    }

    func testCheckpointDuringModeTransitionKeepsTheVisibleContentAnchor() async throws {
        let store = try store()
        let text = "# Reading\n\n" + (1...500).map { "Paragraph \($0).\n\n" }.joined()
        let (session, bridge, _) = try await reader(text, store: store)
        _ = try await bridge.call("scrollToSourceLine", arguments: ["payload": 230])
        // Freeze the actual outgoing animation, rather than guessing when to kill the process.
        _ = try await bridge.webView.evaluateJavaScript(
            "window.MarkdownIt.toggleMode(); document.querySelector('.mdv-reading-layout').getAnimations().forEach(animation => animation.pause());"
        )
        await session.checkpointRecovery()
        bridge.detach()
        _ = await session.document?.closeSavingChanges()
        let next = await restored(ReaderRecoveryStore(directory: store.directory))
        let (restoredBridge, _) = try await mountReader(next)
        XCTAssertEqual(next.mode, "source")
        XCTAssertEqual(restoredBridge.sourceEditor.capturePosition().line, 230, accuracy: 0.15)
    }

    func testCheckpointRejectsLateWritesAfterCloseAndCorruptionIsReported() async throws {
        let store = try store()
        let (session, _, _) = try await reader("# Document\n", store: store)
        await session.checkpointForBackground()
        let loaded = try await store.load()
        let record = try XCTUnwrap(loaded)
        let directory = store.directory
        var values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        let file = directory.appendingPathComponent(record.location.id.uuidString + ".lzfse")
        try await store.remove(token: record.token)
        try await store.save(record)
        let closed = try await store.load()
        XCTAssertNil(closed)
        // Recreate an active checkpoint, then corrupt its payload.
        let reopened = ReaderRecoveryStore(directory: directory)
        try await reopened.save(record)
        try Data("corrupt".utf8).write(to: file)
        do {
            _ = try await store.load()
            XCTFail("Corrupt recovery must not be treated as an empty session")
        } catch { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}

extension RecoveryTests {
    func testAnnotationsRestoreWithSourceUndoAndKeepSavedNotes() async throws {
        let store = try store()
        let original = "# Reading\n\nRemember this sentence.\n"
        let (session, bridge, _) = try await reader(original, store: store)
        let range = (original as NSString).range(of: "Remember this sentence.")
        let saved = await session.setAnnotation(
            ranges: [.init(start: range.location, end: NSMaxRange(range))], note: "A lasting thought",
            token: session.documentToken, sourceRevision: bridge.sourceEditor.history.revision)
        XCTAssertTrue(saved)
        try await sourceMode(bridge)
        let partial = original.replacingOccurrences(of: "this ", with: "")
        XCTAssertTrue(bridge.sourceEditor.replace(expected: original, with: partial, id: "partial"))
        let deleted = partial.replacingOccurrences(of: "Remember sentence.", with: "")
        XCTAssertTrue(bridge.sourceEditor.replace(expected: partial, with: deleted, id: "delete"))
        XCTAssertTrue(session.annotations.visible.isEmpty)
        await session.checkpointForBackground()
        bridge.detach()
        _ = await session.document?.closeSavingChanges()
        let next = await restored(ReaderRecoveryStore(directory: store.directory))
        let (nextBridge, _) = try await mountReader(next)
        XCTAssertTrue(next.annotations.visible.isEmpty)
        XCTAssertTrue(nextBridge.moveSourceHistory(forward: false))
        XCTAssertEqual(next.document?.text, partial)
        XCTAssertEqual(next.annotations.visible.first?.note, "A lasting thought")
        XCTAssertTrue(nextBridge.moveSourceHistory(forward: false))
        XCTAssertEqual(next.document?.text, original)
        XCTAssertEqual(next.annotations.visible.first?.ranges, [.init(start: range.location, end: NSMaxRange(range))])
    }
}

extension RecoveryTests {
    func testUnsubmittedAnnotationRestoresAndCheckpointDoesNotConfirmIME() async throws {
        let store = try store()
        let original = "# Reading\n\nA passage to annotate.\n"
        let (session, bridge, _) = try await reader(original, store: store)
        _ = try await bridge.webView.callAsyncJavaScript(
            """
            const paragraph=document.querySelector('.mdv-article p'),range=document.createRange();
            range.selectNodeContents(paragraph);getSelection().removeAllRanges();getSelection().addRange(range);
            """, arguments: [:], in: nil, contentWorld: .page)
        _ = try await bridge.call("annotationSelectionAction", arguments: ["payload": ["action": "note"]])
        try await wait { bridge.annotationHost.card != nil }
        let card = try XCTUnwrap(bridge.annotationHost.card)
        card.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(card.textView.markedTextRange)
        await session.checkpointRecovery()
        XCTAssertNotNil(card.textView.markedTextRange)
        let loaded = try await store.load()
        XCTAssertEqual(loaded?.annotationDraft?.text, "ni")
        XCTAssertTrue(session.annotations.visible.isEmpty)
        bridge.detach()
        await session.checkpointRecovery(includeWeb: false)
        let detached = try await store.load()
        let detachedDraft = try XCTUnwrap(detached?.annotationDraft)
        XCTAssertEqual(detachedDraft.text, "ni", "A pending checkpoint must retain the draft captured at detach")
        _ = await session.document?.closeSavingChanges()
        let next = await restored(ReaderRecoveryStore(directory: store.directory))
        let (nextBridge, _) = try await mountReader(next)
        try await wait { nextBridge.annotationHost.card != nil }
        XCTAssertEqual(nextBridge.annotationHost.card?.textView.text, "ni")
        XCTAssertTrue(next.annotations.visible.isEmpty)
        XCTAssertEqual(next.document?.text, original)
        nextBridge.annotationHost.dismiss(force: true)
    }
}
