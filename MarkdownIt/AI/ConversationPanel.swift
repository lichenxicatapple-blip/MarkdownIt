import UIKit
import WebKit

/// All panel chrome shares this coordinate space. Only rich content scrolls in WebKit.
@MainActor
final class ConversationPanel: UIView {
    let webView: WKWebView
    let composer: NativeComposerHost
    let clearButton = ConversationControlButton(
        symbol: "trash", title: String(localized: "Clear History"), identifier: "ClearAgentHistory", destructive: true)
    let collapseButton = ConversationControlButton(
        symbol: "chevron.right", title: String(localized: "Collapse conversation"), identifier: "CollapseAgent")
    let sendButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let capsule = UIView()
    private let grabber = UIView()
    private let handle = UIView()
    private let glows = [CAGradientLayer(), CAGradientLayer()]
    var onCollapse: (() -> Void)?
    var onClear: (() -> Void)?
    var onSend: (() -> Void)?
    var onInteraction: (() -> Void)?
    var sheet = false {
        didSet {
            guard sheet != oldValue else { return }
            composer.horizontalInset =
                (sheet ? ReaderDesign.agentCompactInset : ReaderDesign.agentInset) - ReaderDesign.composerMargin - 1
            layer.cornerRadius = sheet ? ReaderDesign.agentSheetRadius : ReaderDesign.agentRadius
            collapseButton.symbol = sheet ? "chevron.down" : "chevron.right"
            grabber.isHidden = !sheet
            layer.maskedCorners =
                sheet
                ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                : [
                    .layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
                ]
            setNeedsLayout()
        }
    }
    var bottomInset: CGFloat = 0 { didSet { setNeedsLayout() } }

    init(webView: WKWebView, composer: NativeComposerHost) {
        self.webView = webView
        self.composer = composer
        super.init(frame: .zero)
        isHidden = true
        accessibilityIdentifier = "ConversationPanel"
        accessibilityLabel = String(localized: "AI Conversation")
        layer.cornerRadius = ReaderDesign.agentRadius
        layer.cornerCurve = .continuous
        clipsToBounds = false
        layer.shadowOffset = CGSize(width: 0, height: 8)
        layer.shadowRadius = 14
        layer.shadowOpacity = 1
        layer.borderWidth = 1
        for (index, glow) in glows.enumerated() {
            glow.masksToBounds = true
            glow.type = .radial
            glow.startPoint = index == 0 ? CGPoint(x: 1, y: 0) : CGPoint(x: 0, y: 1)
            glow.endPoint = index == 0 ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
            glow.locations = [0, index == 0 ? 0.55 : 0.45]
            layer.addSublayer(glow)
        }
        [webView, clearButton, collapseButton, grabber, titleLabel, capsule].forEach(addSubview)
        titleLabel.text = String(localized: "AI Conversation")
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.textColor = .secondaryLabel
        titleLabel.accessibilityIdentifier = "ConversationTitle"
        titleLabel.accessibilityTraits.insert(.header)
        grabber.isHidden = true
        grabber.addSubview(handle)
        capsule.addSubview(composer.view)
        capsule.addSubview(sendButton)
        capsule.layer.cornerRadius = 27
        capsule.layer.borderWidth = 1
        handle.layer.cornerRadius = 2
        clearButton.addAction(UIAction { [weak self] _ in self?.onClear?() }, for: .touchUpInside)
        collapseButton.addAction(UIAction { [weak self] _ in self?.onCollapse?() }, for: .touchUpInside)
        sendButton.addAction(UIAction { [weak self] _ in self?.onSend?() }, for: .touchUpInside)
        sendButton.accessibilityIdentifier = "SendAgentMessage"
        sendButton.layer.cornerRadius = ReaderDesign.hitTarget / 2
        sendButton.isPointerInteractionEnabled = true
        grabber.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        composer.onInteraction = { [weak self] in self?.onInteraction?() }
        composer.onSizeChange = { [weak self] in self?.setNeedsLayout() }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) {
            (view: ConversationPanel, _: UITraitCollection) in
            view.updateColors()
            view.composer.updateTypography()
        }
        updateColors()
        updateControls(hasHistory: false, generating: false, sendEnabled: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(webView:composer:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        for glow in glows {
            glow.frame = bounds
            glow.cornerRadius = layer.cornerRadius
            glow.maskedCorners = layer.maskedCorners
        }
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
        let inset = ReaderDesign.agentControlInset
        let hit = ReaderDesign.hitTarget
        clearButton.frame = CGRect(x: inset, y: inset, width: hit, height: hit)
        collapseButton.frame = CGRect(x: bounds.width - inset - hit, y: inset, width: hit, height: hit)
        grabber.frame = CGRect(
            x: clearButton.frame.maxX, y: inset, width: max(0, collapseButton.frame.minX - clearButton.frame.maxX),
            height: hit)
        titleLabel.frame = grabber.frame.insetBy(dx: inset, dy: 0)
        handle.frame = CGRect(x: (grabber.bounds.width - 32) / 2, y: 0, width: 32, height: 4)
        let margin = ReaderDesign.composerMargin
        let width = max(0, bounds.width - margin * 2)
        let inputWidth = max(1, width - hit - 6)
        let maximum = max(
            ReaderDesign.agentInputMinimum,
            min(ReaderDesign.agentInputMaximum, bounds.height * ReaderDesign.agentInputHeightFraction))
        let height = composer.height(for: inputWidth, maximum: maximum) + 2
        let bottom = max(margin, bottomInset)
        capsule.frame = CGRect(
            x: margin, y: max(inset + hit, bounds.height - bottom - height), width: width, height: height)
        composer.view.frame = CGRect(x: 1, y: 1, width: inputWidth, height: max(0, height - 2))
        sendButton.frame = CGRect(x: width - hit - 5, y: height - hit - 4, width: hit, height: hit)
        let top = inset + hit
        webView.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, capsule.frame.minY - top))
    }

    func updateControls(hasHistory: Bool, generating: Bool, sendEnabled: Bool) {
        clearButton.isEnabled = hasHistory
        sendButton.isEnabled = sendEnabled
        sendButton.alpha = sendEnabled ? 1 : 0.25
        sendButton.setImage(
            UIImage(
                systemName: generating ? "stop.fill" : "arrow.up",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 19)), for: .normal)
        sendButton.accessibilityLabel =
            generating ? String(localized: "Stop generating") : String(localized: "Send message")
    }

    private func updateColors() {
        layer.shadowColor = ReaderDesign.shadow.resolvedColor(with: traitCollection).cgColor
        backgroundColor = ReaderDesign.agentPaper
        layer.borderColor = ReaderDesign.agentLine.resolvedColor(with: traitCollection).cgColor
        let glowColor = ReaderDesign.agentGlow.resolvedColor(with: traitCollection)
        for glow in glows { glow.colors = [glowColor.cgColor, glowColor.withAlphaComponent(0).cgColor] }
        capsule.backgroundColor = ReaderDesign.agentComposer
        capsule.layer.borderColor = ReaderDesign.agentLine.resolvedColor(with: traitCollection).cgColor
        handle.backgroundColor = ReaderDesign.agentLine
        sendButton.backgroundColor = ReaderDesign.agentSend
        sendButton.tintColor = ReaderDesign.agentSendInk
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard sheet else { return }
        onInteraction?()
        let offset = max(0, gesture.translation(in: superview).y)
        switch gesture.state {
        case .began, .changed:
            if !UIAccessibility.isReduceMotionEnabled { transform = CGAffineTransform(translationX: 0, y: offset) }
        case .ended, .cancelled:
            if gesture.state == .ended, offset > 72 { onCollapse?() }
            UIView.animate(
                withDuration: ReaderDesign.agentDuration, delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) { self.transform = .identity }
        default: break
        }
    }
}
