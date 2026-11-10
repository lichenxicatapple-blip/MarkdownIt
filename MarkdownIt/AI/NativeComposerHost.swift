import UIKit
import WebKit

/// UIKit owns editable text and physical keys; the shared surface owns composer layout.
@MainActor
final class NativeComposerHost: NSObject, UITextViewDelegate {
    struct Recovery: Codable, Sendable {
        let text: String
        let selection: NSRange
        let focused: Bool
        let epoch: Int
    }
    var onCheckpoint: (() -> Void)?
    func checkpoint() -> Recovery? {
        guard let view = inputs["question"]?.view else { return nil }
        return Recovery(
            text: view.text ?? "", selection: view.selectedRange,
            focused: view.isFirstResponder || pendingFocus == "question",
            epoch: inputs["question"]?.epoch ?? 0)
    }
    func restore(_ value: Recovery) {
        guard let view = inputs["question"]?.view else { return }
        view.selectedRange = NSRange(
            location: min(max(0, value.selection.location), view.text.utf16.count),
            length: min(
                max(0, value.selection.length), max(0, view.text.utf16.count - max(0, value.selection.location))))
        if value.focused { focus("question") }
    }
    /// Mirror the draft for recovery without ending an active IME composition.
    func synchronize() async {
        guard let input = inputs["question"] else { return }
        await call?("updateAgentInput", ["id": "question", "text": input.view.text ?? "", "epoch": input.epoch])
    }

    /// Input epochs belong to one Web page. Cached recovery data is retained by
    /// the session before a reload; the new page starts its counters at zero.
    func beginPage() {
        blur()
        for id in inputs.keys {
            inputs[id]?.epoch = 0
            inputs[id]?.metrics = []
            inputs[id]?.layoutWidth = 0
            inputs[id]?.measurementKey = ""
            inputs[id]?.measurement = nil
            inputs[id]?.view.text = ""
            inputs[id]?.view.isHidden = true
        }
    }
    private struct Input {
        let view: ConversationTextView
        var epoch = 0
        var metrics: [Double] = []
        var layoutWidth: CGFloat = 0
        var measurementKey = ""
        var measurement: Measurement?
    }
    private struct Measurement: Equatable {
        let text: String
        let epoch: Int
        let key: String
        let height: CGFloat
    }
    private var inputs: [String: Input] = [:]
    private weak var webView: WKWebView?
    private var pendingFocus: String?
    private var resolvingFocus = false
    var call: (@MainActor (String, [String: Any]) async -> Void)?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        for id in ["question"] {
            let view = ConversationTextView()
            view.isHidden = true
            view.backgroundColor = .clear
            view.textColor = .label
            view.tintColor = .tintColor
            view.returnKeyType = .default
            view.contentInsetAdjustmentBehavior = .never
            view.textContainer.lineFragmentPadding = 0
            view.delegate = self
            view.accessibilityLabel = String(localized: "AI message")
            view.accessibilityIdentifier = "QuestionInput"
            view.onSubmit = { [weak self] _ in self?.submit(id) }
            view.onFocusReadinessChange = { [weak self] in self?.resolvePendingFocus() }
            inputs[id] = Input(view: view)
        }
    }

    func updateLayout(_ states: [[String: Any]]) {
        for state in states {
            guard let id = state["id"] as? String, var input = inputs[id] else { continue }
            let visible = state["visible"] as? Bool == true
            let view = input.view
            guard let webView, let host = webView.hostNativeView(view, aboveWebContent: true) else { continue }
            if !visible && view.isFirstResponder { _ = view.resignFirstResponder() }
            view.isHidden = !visible
            view.alpha = state["opacity"] as? Double ?? 1
            let frame = CGRect(
                x: state["x"] as? Double ?? 0, y: state["y"] as? Double ?? 0,
                width: state["width"] as? Double ?? 0, height: state["height"] as? Double ?? 0)
            view.frame = webView.convert(frame, to: host)
            let metrics = ["fontSize", "lineHeight", "top", "right", "bottom", "left"].map { state[$0] as? Double ?? 0 }
            input.layoutWidth = state["layoutWidth"] as? Double ?? frame.width
            input.measurementKey = state["measurementKey"] as? String ?? ""
            if input.metrics != metrics && view.markedTextRange == nil {
                input.metrics = metrics
                let font = UIFont.systemFont(ofSize: max(12, metrics[0]))
                // Keep native glyph/caret metrics; distribute CSS half-leading at the container edges.
                let leading = max(0, metrics[1] - font.lineHeight)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = leading
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .paragraphStyle: paragraph, .foregroundColor: UIColor.label,
                ]
                view.font = font
                view.typingAttributes = attributes
                view.textContainerInset = UIEdgeInsets(
                    top: metrics[2] + leading / 2, left: metrics[5], bottom: metrics[4] + leading / 2,
                    right: metrics[3])
                if !view.text.isEmpty {
                    view.textStorage.addAttributes(
                        attributes, range: NSRange(location: 0, length: view.text.utf16.count))
                }
            }
            inputs[id] = input
            publish(id, includingText: false)
            if visible { host.bringSubviewToFront(view) }
        }
        resolvePendingFocus()
    }

    func setText(id: String, text: String, epoch: Int) {
        guard var input = inputs[id], epoch >= input.epoch else { return }
        input.epoch = epoch
        input.view.text = text
        input.view.selectedRange = NSRange(location: text.utf16.count, length: 0)
        inputs[id] = input
        publish(id, includingText: false)
    }

    func focus(_ id: String) {
        guard inputs[id] != nil else { return }
        pendingFocus = id
        resolvePendingFocus()
    }

    private func resolvePendingFocus() {
        guard !resolvingFocus, let id = pendingFocus, let view = inputs[id]?.view,
            !view.isHidden, !view.bounds.isEmpty, let window = view.window, !window.isHidden
        else { return }
        resolvingFocus = true
        defer { resolvingFocus = false }
        if view.becomeFirstResponder() { pendingFocus = nil }
    }

    func blur() {
        pendingFocus = nil
        for input in inputs.values { _ = input.view.resignFirstResponder() }
    }

    func submit(_ id: String) {
        guard let input = inputs[id] else { return }
        input.view.unmarkText()
        let payload: [String: Any] = ["id": id, "text": input.view.text ?? "", "epoch": input.epoch]
        Task { await call?("commitAgentInput", payload) }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        Task { await call?("agentInteraction", [:]) }
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let id = inputs.first(where: { $0.value.view === textView })?.key else { return }
        publish(id, includingText: true)
    }

    /// TextKit measures the same text, font and wrapping that the user sees.
    /// Web owns the capsule's min/max height and rejects obsolete measurements.
    private func publish(_ id: String, includingText: Bool) {
        guard var input = inputs[id], input.layoutWidth > 0 else { return }
        let height = ceil(
            input.view.sizeThatFits(
                CGSize(width: input.layoutWidth, height: .greatestFiniteMagnitude)
            ).height)
        let measurement = Measurement(
            text: input.view.text ?? "", epoch: input.epoch, key: input.measurementKey, height: height)
        guard includingText || input.measurement != measurement else { return }
        input.measurement = measurement
        inputs[id] = input
        let payload: [String: Any] = [
            "id": id, "text": measurement.text, "epoch": measurement.epoch,
            "measurementKey": measurement.key, "height": height,
        ]
        Task {
            await call?(includingText ? "updateAgentInput" : "resizeAgentInput", payload)
            if includingText { onCheckpoint?() }
        }
    }

    func textViewDidChangeSelection(_ textView: UITextView) { onCheckpoint?() }

    func detach() {
        blur()
        for input in inputs.values {
            input.view.onFocusReadinessChange = nil
            input.view.removeFromSuperview()
            input.view.delegate = nil
            input.view.onSubmit = nil
        }
        inputs.removeAll()
        call = nil
    }
}
