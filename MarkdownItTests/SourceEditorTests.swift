import UIKit
import XCTest

@testable import MarkdownIt

final class SourceEditorTests: XCTestCase {
    @MainActor
    func testSerializedHistoryRestoresBothStacksAndTheirSelections() throws {
        let history = SourceHistory()
        let original = "👩🏽‍💻\n"
        history.reset(original)
        let firstSelection = SourceSelection(range: NSRange(location: original.utf16.count + 5, length: 0), scrollY: 42)
        history.record(
            original + "Hello", before: SourceSelection(range: NSRange(location: original.utf16.count, length: 0)),
            after: firstSelection, id: "manual")
        history.record(original + "Hello world", before: firstSelection, id: "agent")
        XCTAssertTrue(history.move(forward: false))
        let snapshot = try JSONDecoder().decode(
            SourceHistory.Snapshot.self, from: JSONEncoder().encode(history.snapshot()))
        let restored = SourceHistory()
        var changes: [SourceSelection] = []
        restored.onChange = { selection, _, _ in changes.append(selection) }
        try restored.restore(snapshot)
        XCTAssertTrue(changes.isEmpty, "Loading history must not replay document edits or emit tool results")
        XCTAssertEqual(restored.text, original + "Hello")
        XCTAssertEqual(restored.revision, history.revision)
        XCTAssertTrue(restored.canUndo)
        XCTAssertTrue(restored.canRedo)
        XCTAssertTrue(restored.move(forward: false, id: "manual"))
        XCTAssertEqual(restored.text, original)
        XCTAssertTrue(restored.move(forward: true, id: "manual"))
        XCTAssertEqual(changes.last, firstSelection)
        XCTAssertTrue(restored.move(forward: true, id: "agent"))
        XCTAssertEqual(restored.text, original + "Hello world")
        XCTAssertFalse(restored.canRedo)
        XCTAssertTrue(restored.move(forward: false))
        restored.record(original + "A new branch", before: firstSelection)
        XCTAssertFalse(restored.canRedo)
    }

    @MainActor
    func testHistorySnapshotDoesNotChangeWhenTypingContinues() throws {
        let history = SourceHistory()
        history.reset("")
        history.record("a", before: SourceSelection(range: NSRange(location: 0, length: 0)), kind: .typing)
        let snapshot = history.snapshot()
        history.record("ab", before: SourceSelection(range: NSRange(location: 1, length: 0)), kind: .typing)
        let restored = SourceHistory()
        try restored.restore(snapshot)
        XCTAssertEqual(restored.text, "a")
        XCTAssertTrue(restored.move(forward: false))
        XCTAssertEqual(restored.text, "")
        XCTAssertEqual(history.text, "ab")
    }

    @MainActor
    func testCorruptRestoredHistoryCannotReplaceTheCurrentBuffer() throws {
        let history = SourceHistory()
        history.reset("Original")
        history.record("Changed", before: SourceSelection(range: NSRange(location: 0, length: 0)))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(history.snapshot())) as? [String: Any])
        var transactions = try XCTUnwrap(object["undo"] as? [[String: Any]])
        transactions[0]["start"] = Int.max
        object["undo"] = transactions
        let corrupt = try JSONDecoder().decode(
            SourceHistory.Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        let restored = SourceHistory()
        restored.reset("Keep this buffer")
        XCTAssertThrowsError(try restored.restore(corrupt))
        XCTAssertEqual(restored.text, "Keep this buffer")
        XCTAssertFalse(restored.canUndo)
    }

    @MainActor
    func testDetachingFocusedEditorDoesNotPublishDocumentChanges() throws {
        let (editor, window) = try editor("Unchanged document")
        defer { window.isHidden = true }
        XCTAssertTrue(editor.textView.isFirstResponder)
        var documentChanges = 0
        editor.onChange = { _, _ in documentChanges += 1 }
        editor.detach()
        XCTAssertFalse(editor.textView.isFirstResponder)
        XCTAssertNil(editor.textView.superview)
        XCTAssertEqual(documentChanges, 0)
    }

    @MainActor
    func testSourceDelegateReceivesSystemMultiRangeInputAndMenuRequests() throws {
        let (editor, window) = try editor("Source selection")
        defer {
            editor.detach()
            window.isHidden = true
        }
        let view = editor.textView
        let delegate = try XCTUnwrap(view.delegate)
        view.selectedRange = NSRange(location: 0, length: 6)
        let ranges = [NSValue(range: view.selectedRange)]
        XCTAssertTrue(
            editor.responds(to: #selector(UITextViewDelegate.textView(_:shouldChangeTextInRanges:replacementText:))))
        XCTAssertEqual(delegate.textView?(view, shouldChangeTextInRanges: ranges, replacementText: "Text"), true)
        XCTAssertTrue(
            editor.responds(to: #selector(UITextViewDelegate.textView(_:editMenuForTextInRanges:suggestedActions:))))
        let menu = try XCTUnwrap(delegate.textView?(view, editMenuForTextInRanges: ranges, suggestedActions: []))
        func actions(_ menu: UIMenu) -> [UIAction] {
            menu.children.flatMap { element -> [UIAction] in
                if let action = element as? UIAction { return [action] }
                if let child = element as? UIMenu { return actions(child) }
                return []
            }
        }
        XCTAssertEqual(actions(menu).map(\.title), [String(localized: "Reference in AI Chat…")])
        view.selectedRange = NSRange(location: 0, length: 0)
        let emptyMenu = try XCTUnwrap(
            delegate.textView?(
                view, editMenuForTextInRanges: [NSValue(range: view.selectedRange)], suggestedActions: []))
        XCTAssertTrue(actions(emptyMenu).isEmpty)
    }

    @MainActor
    private func editor(_ text: String = "") throws -> (SourceEditor, UIWindow) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let editor = SourceEditor()
        editor.load(text)
        controller.view.addSubview(editor.textView)
        editor.updateLayout(frame: controller.view.bounds, visible: true, opacity: 1)
        editor.textView.becomeFirstResponder()
        return (editor, window)
    }

    @MainActor
    func testNativeTypingUndoRedoAndNewBranch() throws {
        let (editor, window) = try editor()
        defer {
            editor.detach()
            window.isHidden = true
        }
        XCTAssertNotNil(editor.textView.textLayoutManager)
        for character in "Hello" { editor.textView.insertText(String(character)) }
        XCTAssertEqual(editor.history.text, "Hello")
        XCTAssertTrue(editor.history.move(forward: false))
        XCTAssertEqual(editor.textView.text, "")
        XCTAssertFalse(editor.history.canUndo)
        XCTAssertTrue(editor.history.move(forward: true))
        XCTAssertEqual(editor.textView.text, "Hello")
        XCTAssertTrue(editor.history.move(forward: false))
        editor.textView.insertText("New")
        XCTAssertEqual(editor.history.text, "New")
        XCTAssertFalse(editor.history.canRedo)
        XCTAssertEqual(editor.history.undoManager.groupingLevel, 0)
    }

    @MainActor
    func testMarkedTextCommitsAsOneTransactionAndPreservesUnicode() throws {
        let (editor, window) = try editor("👩🏽‍💻 ")
        defer {
            editor.detach()
            window.isHidden = true
        }
        editor.textView.selectedRange = NSRange(location: editor.history.text.utf16.count, length: 0)
        editor.textView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(editor.history.text, "👩🏽‍💻 ")
        editor.textView.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
        editor.textView.unmarkText()
        XCTAssertEqual(editor.history.text, "👩🏽‍💻 中文")
        XCTAssertTrue(editor.history.move(forward: false))
        XCTAssertEqual(editor.textView.text, "👩🏽‍💻 ")
        XCTAssertFalse(editor.history.canUndo)
        XCTAssertTrue(editor.history.move(forward: true))
        XCTAssertEqual(editor.textView.text, "👩🏽‍💻 中文")
    }

    @MainActor
    func testCandidateInsertionCommitsCompositionBeforeSubsequentTyping() throws {
        let (editor, window) = try editor()
        defer {
            editor.detach()
            window.isHidden = true
        }
        editor.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        editor.textView.insertText("你")
        XCTAssertNil(editor.textView.markedTextRange)
        XCTAssertEqual(editor.history.text, "你")
        editor.textView.insertText("好")
        XCTAssertEqual(editor.history.text, "你好")
        editor.history.undoManager.undo()
        XCTAssertEqual(editor.textView.text, "你")
        editor.history.undoManager.undo()
        XCTAssertEqual(editor.textView.text, "")
    }

    @MainActor
    func testAgentTransactionCannotUndoOverLaterManualInput() throws {
        let (editor, window) = try editor("# Draft\n")
        defer {
            editor.detach()
            window.isHidden = true
        }
        XCTAssertTrue(editor.replace(expected: "# Draft\n", with: "# Final\n", id: "agent-edit"))
        XCTAssertFalse(editor.replace(expected: "# Draft\n", with: "stale"))
        editor.textView.selectedRange = NSRange(location: editor.history.text.utf16.count, length: 0)
        editor.textView.insertText("More")
        XCTAssertFalse(editor.history.move(forward: false, id: "agent-edit"))
        XCTAssertTrue(editor.history.move(forward: false))
        XCTAssertEqual(editor.textView.text, "# Final\n")
        XCTAssertTrue(editor.history.move(forward: false, id: "agent-edit"))
        XCTAssertEqual(editor.textView.text, "# Draft\n")
        XCTAssertTrue(editor.history.move(forward: true, id: "agent-edit"))
        XCTAssertEqual(editor.textView.text, "# Final\n")
    }

    @MainActor
    func testLongWrappedDocumentPositionSurvivesModeRoundTrip() throws {
        let text = (1...100).map { "\($0) " + String(repeating: "正文 and source words. ", count: 12) }.joined(
            separator: "\n")
        let (editor, window) = try editor(text)
        defer {
            editor.detach()
            window.isHidden = true
        }
        editor.textView.resignFirstResponder()
        let target = SourceReadingPosition(line: 48.35, y: 76)
        editor.restore(target)
        XCTAssertEqual(editor.capturePosition(), target)
        editor.updateLayout(frame: editor.textView.frame, visible: false, opacity: 0)
        editor.restore(target)
        editor.updateLayout(frame: editor.textView.frame, visible: true, opacity: 1)
        XCTAssertEqual(editor.capturePosition(), target)
        XCTAssertGreaterThan(editor.textView.contentOffset.y, 0)
        XCTAssertEqual(editor.textView.textContainer.lineFragmentPadding, 0)
    }

    @MainActor
    func testMarkdownTypingDeletionAndExternalEditKeepOneHistory() throws {
        let (editor, window) = try editor()
        defer {
            editor.detach()
            window.isHidden = true
        }
        for character in "**undo-check** " { editor.textView.insertText(String(character)) }
        XCTAssertEqual(editor.history.undoManager.undoCount, 1)
        editor.history.undoManager.undo()
        XCTAssertEqual(editor.history.text, "")
        editor.history.undoManager.redo()
        editor.textView.deleteBackward()
        editor.textView.deleteBackward()
        XCTAssertEqual(editor.history.text, "**undo-check*")
        editor.history.undoManager.undo()
        XCTAssertEqual(editor.textView.text, "**undo-check** ")
        editor.textView.selectedRange = NSRange(location: 5, length: 4)
        XCTAssertTrue(editor.replace(expected: editor.history.text, with: "prefix **undo-check** ", id: "prefix"))
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 12, length: 4))
        editor.history.undoManager.undo()
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 5, length: 4))
        XCTAssertTrue(editor.history.canRedo)
    }

    @MainActor
    func testRepeatedCharactersUseNativeSelectionToLocateEdits() throws {
        let (editor, window) = try editor("title\n\nbody")
        defer {
            editor.detach()
            window.isHidden = true
        }
        editor.textView.selectedRange = NSRange(location: 6, length: 0)
        editor.textView.deleteBackward()
        editor.textView.deleteBackward()
        XCTAssertEqual(editor.history.text, "titl\nbody")
        XCTAssertEqual(editor.history.undoManager.undoCount, 1)
        editor.history.undoManager.undo()
        XCTAssertEqual(editor.textView.text, "title\n\nbody")
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 6, length: 0))
        editor.load("aaaa")
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        editor.textView.insertText("a")
        editor.textView.insertText("a")
        XCTAssertEqual(editor.history.text, "aaaaaa")
        editor.history.undoManager.undo()
        XCTAssertEqual(editor.textView.text, "aaaa")
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 0, length: 0))
    }

    @MainActor
    func testSystemUndoManagerUsesSameHistory() throws {
        let (editor, window) = try editor("First")
        defer {
            editor.detach()
            window.isHidden = true
        }
        editor.textView.selectedRange = NSRange(location: 5, length: 0)
        editor.textView.insertText(" second")
        let manager = try XCTUnwrap(editor.textView.undoManager)
        XCTAssertTrue(manager === editor.history.undoManager)
        manager.undo()
        XCTAssertEqual(editor.history.text, "First")
        XCTAssertEqual(editor.textView.text, "First")
        manager.redo()
        XCTAssertEqual(editor.history.text, "First second")
        XCTAssertEqual(editor.textView.text, "First second")
    }
}
