import UIKit
import WebKit

/// Web reserves one header row; UIKit owns its symbols, touch targets and glass feedback.
@MainActor
final class ConversationControlsHost {
    let clearButton = ConversationControlButton(
        symbol: "trash", title: String(localized: "Clear History"), identifier: "ClearAgentHistory", destructive: true)
    let collapseButton = ConversationControlButton(
        symbol: "chevron.right", title: String(localized: "Collapse conversation"), identifier: "CollapseAgent")
    var onClear: ((String) -> Void)?
    var onCollapse: ((String) -> Void)?
    private weak var webView: WKWebView?
    private var token = ""

    init(webView: WKWebView) {
        self.webView = webView
        clearButton.addAction(
            UIAction { [weak self] _ in
                guard let self, self.clearButton.isEnabled else { return }
                self.onClear?(self.token)
            }, for: .touchUpInside)
        collapseButton.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.onCollapse?(self.token)
            }, for: .touchUpInside)
    }

    func updateLayout(_ states: [[String: Any]], token: String) {
        self.token = token
        for state in states {
            let button: ConversationControlButton
            switch state["id"] as? String {
            case "clear": button = clearButton
            case "collapse": button = collapseButton
            default: continue
            }
            guard let webView, let host = webView.hostNativeView(button, aboveWebContent: true) else { continue }
            let frame = CGRect(
                x: state["x"] as? Double ?? 0, y: state["y"] as? Double ?? 0,
                width: state["width"] as? Double ?? 0, height: state["height"] as? Double ?? 0)
            button.frame = webView.convert(frame, to: host)
            button.isHidden = state["visible"] as? Bool != true
            button.isEnabled = state["enabled"] as? Bool == true
            button.presentationOpacity = state["opacity"] as? Double ?? 1
            if button === collapseButton {
                button.symbol = state["sheet"] as? Bool == true ? "chevron.down" : "chevron.right"
            }
            host.bringSubviewToFront(button)
        }
    }

    func hide() {
        clearButton.isHidden = true
        collapseButton.isHidden = true
    }

    func detach() {
        clearButton.removeFromSuperview()
        collapseButton.removeFromSuperview()
        onClear = nil
        onCollapse = nil
    }
}

@MainActor
final class ConversationControlButton: UIButton {
    private let material = UIVisualEffectView(effect: nil)
    private let glass = UIGlassEffect(style: .regular)
    private var hovering = false
    private var showingMaterial = false
    var presentationOpacity: CGFloat = 1 { didSet { updateOpacity() } }
    var symbol: String { didSet { if symbol != oldValue { updateSymbol() } } }

    init(symbol: String, title: String, identifier: String, destructive: Bool = false) {
        self.symbol = symbol
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = destructive ? .systemRed : .secondaryLabel
        configuration.background.backgroundColor = .clear
        configuration.cornerStyle = .capsule
        self.configuration = configuration
        accessibilityLabel = title
        accessibilityIdentifier = identifier
        isHidden = true
        isPointerInteractionEnabled = true
        glass.isInteractive = true
        material.cornerConfiguration = .capsule()
        material.isUserInteractionEnabled = false
        material.accessibilityElementsHidden = true
        insertSubview(material, at: 0)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:))))
        updateSymbol()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(symbol:title:identifier:destructive:)") }

    override var isHighlighted: Bool { didSet { updateMaterial() } }
    override var isEnabled: Bool {
        didSet {
            updateOpacity()
            updateMaterial()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = min(ReaderDesign.agentControlSurface, bounds.width, bounds.height)
        material.frame = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        updateMaterial()
    }

    @objc private func hoverChanged(_ gesture: UIHoverGestureRecognizer) {
        hovering = gesture.state == .began || gesture.state == .changed
        updateMaterial()
    }

    private func updateSymbol() {
        configuration?.image = ReaderChromeSymbols.symbol(symbol, pointSize: ReaderDesign.agentControlIcon)
    }

    private func updateOpacity() { alpha = presentationOpacity * (isEnabled ? 1 : 0.35) }

    private func updateMaterial() {
        let shown = isEnabled && (isHighlighted || isFocused || hovering)
        guard shown != showingMaterial else { return }
        showingMaterial = shown
        let change = { self.material.effect = shown ? self.glass : nil }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.performWithoutAnimation(change)
        } else {
            UIView.animate(
                withDuration: ReaderDesign.materialDuration, delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: change)
        }
    }
}
