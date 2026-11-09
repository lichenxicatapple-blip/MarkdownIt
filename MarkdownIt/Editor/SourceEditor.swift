import UIKit

struct SourceReadingPosition: Codable, Equatable, Sendable {
    let line: Double
    let y: CGFloat
    let atStart: Bool

    init(line: Double, y: CGFloat = ReaderDesign.sourceTopInset, atStart: Bool = false) {
        self.line = line
        self.y = y
        self.atStart = atStart
    }

    init(_ value: [String: Any]) {
        self.init(
            line: (value["line"] as? NSNumber)?.doubleValue ?? 0,
            y: CGFloat((value["y"] as? NSNumber)?.doubleValue ?? Double(ReaderDesign.sourceTopInset)),
            atStart: value["atStart"] as? Bool ?? false)
    }

    var payload: [String: Any] { ["line": line, "y": y, "atStart": atStart] }
}

final class SourceTextView: UITextView {
    var sourceUndoManager: UndoManager?
    var onCompositionBegin: (() -> Void)?
    var onCompositionCommit: (() -> Void)?
    var onPaste: (() -> Void)?

    override var undoManager: UndoManager? { sourceUndoManager }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if markedTextRange == nil { onCompositionBegin?() }
        super.setMarkedText(markedText, selectedRange: selectedRange)
        if markedTextRange == nil { onCompositionCommit?() }
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionCommit?()
    }

    override func paste(_ sender: Any?) {
        onPaste?()
        super.paste(sender)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        onPaste?()
        super.paste(itemProviders: itemProviders)
    }
}

/// A persistent native editor; hiding it for preview does not reset its working history.
@MainActor
final class SourceEditor: NSObject, UITextViewDelegate {
    struct Recovery: Codable, Sendable {
        let history: SourceHistory.Snapshot
        let selection: SourceSelection
        let position: SourceReadingPosition
        let focused: Bool
    }
    let history = SourceHistory()
    let textView = SourceTextView(usingTextLayoutManager: true)
    var onChange: ((String?, String?) -> Void)?
    var onAsk: ((NSRange) -> Void)?
    var onCheckpoint: (() -> Void)?
    private var restoreFocus = false
    private var updating = false
    private var composing = false
    private var pendingSelection: SourceSelection?
    private var pendingKind = SourceHistory.InputKind.typing
    private var previousSelection = SourceSelection(range: NSRange(location: 0, length: 0))
    private var pendingPosition: SourceReadingPosition?
    private var restoredPosition: (SourceReadingPosition, CGFloat, CGFloat, Int)?

    override init() {
        super.init()
        textView.sourceUndoManager = history.undoManager
        textView.delegate = self
        textView.backgroundColor = .systemBackground
        textView.textColor = .label
        textView.tintColor = .tintColor
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: ReaderDesign.sourceSize, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(
            top: ReaderDesign.sourceTopInset, left: ReaderDesign.sourceHorizontalInset,
            bottom: ReaderDesign.sourceBottomInset, right: ReaderDesign.sourceHorizontalInset)
        textView.contentInsetAdjustmentBehavior = .never
        textView.keyboardDismissMode = .interactive
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.autocapitalizationType = .none
        textView.accessibilityLabel = String(localized: "Markdown source")
        textView.accessibilityIdentifier = "SourceEditor"
        textView.isHidden = true
        textView.onCompositionBegin = { [weak self] in
            guard let self, !self.composing else { return }
            self.composing = true
            self.history.breakGroup()
            self.pendingSelection = self.selection
        }
        textView.onCompositionCommit = { [weak self] in
            guard let self, self.composing, self.textView.markedTextRange == nil else { return }
            self.composing = false
            self.commit(kind: .composition)
        }
        textView.onPaste = { [weak self] in
            self?.history.breakGroup()
            self?.pendingKind = .transaction
        }
        history.onChange = { [weak self] selection, id, status in
            guard let self else { return }
            if self.textView.text != self.history.text {
                self.updating = true
                self.textView.text = self.history.text
                self.textView.selectedRange = selection.range
                self.textView.setContentOffset(CGPoint(x: 0, y: selection.scrollY), animated: false)
                self.updating = false
            }
            self.previousSelection = selection
            self.restoredPosition = nil
            self.onChange?(id, status)
        }
    }

    var selection: SourceSelection {
        SourceSelection(range: textView.selectedRange, scrollY: textView.contentOffset.y)
    }

    func checkpoint() -> Recovery {
        Recovery(
            history: history.snapshot(), selection: selection, position: capturePosition(),
            focused: textView.isFirstResponder || restoreFocus)
    }

    func restore(_ value: Recovery) throws {
        let length = (value.history.text as NSString).length
        guard value.selection.range.location >= 0, value.selection.range.length >= 0,
            value.selection.range.location <= length,
            value.selection.range.length <= length - value.selection.range.location,
            value.selection.scrollY.isFinite, value.position.line.isFinite, value.position.y.isFinite
        else { throw CocoaError(.coderReadCorrupt) }
        try history.restore(value.history)
        updating = true
        textView.text = history.text
        textView.selectedRange = value.selection.range
        updating = false
        previousSelection = value.selection
        restoreFocus = value.focused
        restore(value.position)
    }

    func load(_ text: String) {
        updating = true
        textView.unmarkText()
        history.reset(text)
        textView.text = text
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.contentOffset = .zero
        updating = false
        pendingSelection = nil
        composing = false
        pendingPosition = nil
        restoredPosition = nil
        restoreFocus = false
        previousSelection = selection
    }

    func commitInput() {
        textView.unmarkText()
        if textView.text != history.text { commit(kind: composing ? .composition : .transaction) }
    }

    @discardableResult
    func replace(expected: String, with text: String, id: String? = nil, changes: [SourceHistory.Edit.Delta]? = nil)
        -> Bool
    {
        commitInput()
        guard history.text == expected else { return false }
        history.record(text, before: selection, id: id ?? UUID().uuidString.lowercased(), changes: changes)
        return true
    }

    private func commit(kind: SourceHistory.InputKind) {
        guard !updating else { return }
        history.record(textView.text, before: pendingSelection ?? previousSelection, after: selection, kind: kind)
        pendingSelection = nil
        pendingKind = .typing
    }

    func textView(
        _ textView: UITextView, shouldChangeTextInRanges ranges: [NSValue], replacementText text: String
    ) -> Bool {
        if !composing { pendingSelection = selection }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !updating, textView.markedTextRange == nil else { return }
        let kind = composing ? .composition : pendingKind
        composing = false
        commit(kind: kind)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !updating, !composing, textView.markedTextRange == nil, textView.text == history.text else { return }
        if pendingSelection == nil && selection.range != previousSelection.range { history.breakGroup() }
        previousSelection = selection
        onCheckpoint?()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !updating { onCheckpoint?() }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        commitInput()
        history.breakGroup()
    }

    func textView(
        _ textView: UITextView, editMenuForTextInRanges ranges: [NSValue], suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard textView.selectedRange.length > 0 else { return UIMenu(children: suggestedActions) }
        let ai = UIAction(title: String(localized: "Reference in AI Chat…"), image: UIImage(systemName: "bubble.left"))
        {
            [weak self] _ in
            guard let self, self.textView.selectedRange.length > 0 else { return }
            self.onAsk?(self.textView.selectedRange)
        }
        return UIMenu(children: suggestedActions + [UIMenu(options: .displayInline, children: [ai])])
    }

    func requestFocus() {
        restoreFocus = true
        if !textView.isHidden, textView.isUserInteractionEnabled, textView.window != nil {
            restoreFocus = !textView.becomeFirstResponder()
        }
    }

    func updateLayout(frame: CGRect, visible: Bool, opacity: CGFloat, interactive: Bool = true) {
        let position =
            visible && !textView.isHidden && abs(textView.bounds.width - frame.width) > 0.5
            ? capturePosition() : nil
        if !visible || !interactive { textView.resignFirstResponder() }
        textView.isUserInteractionEnabled = interactive
        textView.accessibilityElementsHidden = !interactive
        textView.isAccessibilityElement = interactive
        textView.frame = frame
        textView.isHidden = !visible
        textView.alpha = opacity
        if restoreFocus, visible, interactive, textView.window != nil {
            restoreFocus = !textView.becomeFirstResponder()
        }
        if visible, let position = pendingPosition {
            pendingPosition = nil
            restore(position)
        } else if let position {
            restore(position)
        }
    }

    func restore(_ position: SourceReadingPosition) {
        guard !textView.isHidden, textView.bounds.width > 0, textView.bounds.height > 0 else {
            pendingPosition = position
            return
        }
        let lines = history.text.components(separatedBy: "\n")
        let index = min(max(0, Int(position.line)), max(0, lines.count - 1))
        let start = lines.prefix(index).reduce(0) { $0 + $1.utf16.count + 1 }
        let end = start + lines[index].utf16.count
        textView.scrollRangeToVisible(NSRange(location: start, length: 0))
        textView.layoutIfNeeded()
        guard let first = textView.position(from: textView.beginningOfDocument, offset: start),
            let last = textView.position(from: textView.beginningOfDocument, offset: end)
        else { return }
        let firstRect = textView.caretRect(for: first)
        let lastRect = textView.caretRect(for: last)
        let height = max(firstRect.height, lastRect.maxY - firstRect.minY)
        let target = firstRect.minY + (position.line - floor(position.line)) * height - position.y
        let maximum = max(0, textView.contentSize.height - textView.bounds.height)
        textView.setContentOffset(
            CGPoint(x: 0, y: position.atStart ? 0 : min(maximum, max(0, target))), animated: false)
        restoredPosition = (position, textView.contentOffset.y, textView.bounds.width, history.revision)
    }

    func capturePosition() -> SourceReadingPosition {
        if let pendingPosition { return pendingPosition }
        if let (position, offset, width, revision) = restoredPosition,
            abs(offset - textView.contentOffset.y) < 1, abs(width - textView.bounds.width) < 1,
            revision == history.revision
        {
            return position
        }
        let y = textView.textContainerInset.top
        let point = CGPoint(x: textView.textContainerInset.left, y: textView.contentOffset.y + y)
        guard let position = textView.closestPosition(to: point) else { return SourceReadingPosition(line: 0) }
        let offset = textView.offset(from: textView.beginningOfDocument, to: position)
        let text = history.text as NSString
        let prefix = text.substring(to: min(offset, text.length))
        let index = prefix.components(separatedBy: "\n").count - 1
        let range = text.lineRange(for: NSRange(location: min(offset, text.length), length: 0))
        guard let first = textView.position(from: textView.beginningOfDocument, offset: range.location),
            let last = textView.position(
                from: textView.beginningOfDocument, offset: max(range.location, NSMaxRange(range) - 1))
        else { return SourceReadingPosition(line: Double(index), y: y) }
        let firstRect = textView.caretRect(for: first)
        let lastRect = textView.caretRect(for: last)
        let height = max(firstRect.height, lastRect.maxY - firstRect.minY)
        let fraction = min(0.9999, max(0, (point.y - firstRect.minY) / max(1, height)))
        return SourceReadingPosition(line: Double(index) + fraction, y: y, atStart: textView.contentOffset.y < 1)
    }

    func detach() {
        // SwiftUI can dismantle the host during a view update. Disconnect the
        // outgoing editor before UIKit sends its editing-ending callbacks.
        onChange = nil
        onAsk = nil
        textView.delegate = nil
        textView.resignFirstResponder()
        textView.removeFromSuperview()
        history.onChange = nil
        history.reset("")
    }
}
