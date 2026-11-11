import UIKit

@MainActor
final class ConversationControlButton: UIButton {
    private let material = UIVisualEffectView(effect: nil)
    private let glass = UIGlassEffect(style: .regular)
    private var hovering = false
    private var showingMaterial = false
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

    private func updateOpacity() { alpha = isEnabled ? 1 : 0.35 }

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
