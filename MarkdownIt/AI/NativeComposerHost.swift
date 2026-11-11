import UIKit

/// One native draft input. TextKit owns measurement; its panel owns placement.
@MainActor
final class NativeComposerHost: NSObject, UITextViewDelegate {
    struct Recovery: Codable, Sendable {
        let text: String
        let selection: NSRange
        let focused: Bool
        let epoch: Int
    }
    let view = ConversationTextView()
    var onCheckpoint: (() -> Void)?
    var onInteraction: (() -> Void)?
    var onSizeChange: (() -> Void)?
    var call: (@MainActor (String, [String: Any]) async -> Void)?
    var horizontalInset = ReaderDesign.agentInset - ReaderDesign.composerMargin - 1 {
        didSet {
            guard horizontalInset != oldValue else { return }
            view.textContainerInset.left = horizontalInset
            view.textContainerInset.right = horizontalInset
            onSizeChange?()
        }
    }
    private var epoch = 0
    private var pendingFocus = false
    private var resolvingFocus = false

    override init() {
        super.init()
        view.isHidden = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.tintColor = ReaderDesign.agentAccent
        view.returnKeyType = .default
        view.contentInsetAdjustmentBehavior = .never
        view.textContainer.lineFragmentPadding = 0
        view.delegate = self
        view.accessibilityLabel = String(localized: "AI message")
        view.accessibilityIdentifier = "QuestionInput"
        view.onSubmit = { [weak self] _ in self?.submit("question") }
        view.onFocusReadinessChange = { [weak self] in self?.resolvePendingFocus() }
        updateTypography()
    }

    func updateTypography() {
        guard view.markedTextRange == nil else { return }
        let size = UIFontMetrics(forTextStyle: .body).scaledValue(for: 16, compatibleWith: view.traitCollection)
        let font = UIFont.systemFont(ofSize: size)
        let leading = max(0, size * 1.65 - font.lineHeight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = leading
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph, .foregroundColor: UIColor.label,
        ]
        view.font = font
        view.typingAttributes = attributes
        let inset = horizontalInset
        view.textContainerInset = UIEdgeInsets(
            top: 12 + leading / 2, left: inset, bottom: 12 + leading / 2, right: inset)
        if !view.text.isEmpty {
            view.textStorage.addAttributes(attributes, range: NSRange(location: 0, length: view.text.utf16.count))
        }
        onSizeChange?()
    }

    func height(for width: CGFloat, maximum: CGFloat) -> CGFloat {
        min(
            maximum,
            max(
                ReaderDesign.agentInputMinimum,
                ceil(view.sizeThatFits(CGSize(width: max(1, width), height: .greatestFiniteMagnitude)).height)))
    }

    func setVisible(_ visible: Bool) {
        if !visible { blur() }
        view.isHidden = !visible
        resolvePendingFocus()
    }

    func checkpoint() -> Recovery? {
        Recovery(
            text: view.text ?? "", selection: view.selectedRange, focused: view.isFirstResponder || pendingFocus,
            epoch: epoch)
    }
    func restore(_ value: Recovery) {
        let count = view.text.utf16.count
        let location = min(max(0, value.selection.location), count)
        view.selectedRange = NSRange(location: location, length: min(max(0, value.selection.length), count - location))
        if value.focused { focus("question") }
    }
    func synchronize() async {
        await call?("updateAgentInput", ["id": "question", "text": view.text ?? "", "epoch": epoch])
    }
    func beginPage() {
        blur()
        epoch = 0
        view.text = ""
        view.isHidden = true
        onSizeChange?()
    }
    func setText(id: String, text: String, epoch: Int) {
        guard id == "question", epoch >= self.epoch else { return }
        self.epoch = epoch
        // A matching draft update must not replace an active IME composition.
        if view.text != text {
            view.text = text
            view.selectedRange = NSRange(location: text.utf16.count, length: 0)
        }
        onSizeChange?()
    }
    func focus(_ id: String) {
        guard id == "question" else { return }
        pendingFocus = true
        resolvePendingFocus()
    }
    private func resolvePendingFocus() {
        guard !resolvingFocus, pendingFocus, !view.isHidden, !view.bounds.isEmpty,
            let window = view.window, !window.isHidden, !view.ancestorsHidden
        else { return }
        resolvingFocus = true
        defer { resolvingFocus = false }
        if view.becomeFirstResponder() { pendingFocus = false }
    }
    func blur() {
        pendingFocus = false
        _ = view.resignFirstResponder()
    }
    func submit(_ id: String) {
        guard id == "question" else { return }
        view.unmarkText()
        let payload: [String: Any] = ["id": id, "text": view.text ?? "", "epoch": epoch]
        Task { await call?("commitAgentInput", payload) }
    }
    func textViewDidBeginEditing(_ textView: UITextView) {
        onInteraction?()
        onSizeChange?()
    }
    func textViewDidChange(_ textView: UITextView) {
        onInteraction?()
        onSizeChange?()
        Task {
            await synchronize()
            onCheckpoint?()
        }
    }
    func textViewDidChangeSelection(_ textView: UITextView) { onCheckpoint?() }
    func detach() {
        blur()
        view.onFocusReadinessChange = nil
        view.delegate = nil
        view.onSubmit = nil
        view.removeFromSuperview()
        call = nil
        onSizeChange = nil
    }
}

extension UIView {
    fileprivate var ancestorsHidden: Bool {
        var ancestor = superview
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 { return true }
            ancestor = view.superview
        }
        return false
    }
}
