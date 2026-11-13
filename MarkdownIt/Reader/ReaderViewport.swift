import UIKit
import WebKit

extension WKWebView {
    /// Native inputs and controls stay outside WebKit's keyboard/responder hierarchy.
    func hostNativeView(_ input: UIView, aboveWebContent: Bool) -> UIView? {
        guard let host = superview else { return nil }
        if input.superview !== host {
            if aboveWebContent {
                host.insertSubview(input, aboveSubview: self)
            } else {
                host.insertSubview(input, belowSubview: self)
            }
        }
        return host
    }
}

@MainActor
final class ReaderViewport: UIView {
    let webView: ReaderWKWebView
    private let inputBoundary = ReaderKeyboardRegion()
    private let scrim = UIControl()
    private var previousLayout: ReaderWorkspace.Layout?
    private var previousBounds = CGRect.zero
    private var presentationRevision = 0
    private var previousAgent = false
    private var previousPanelFrame = CGRect.zero

    override var keyCommands: [UIKeyCommand]? {
        let find = UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(findDocument(_:)))
        find.discoverabilityTitle = String(localized: "Find in Document")
        find.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [find]
    }

    @objc private func findDocument(_ sender: UIKeyCommand) { webView.findDocument?() }

    init(webView: ReaderWKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .systemBackground
        webView.autoresizingMask = []
        addSubview(webView)
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.14)
        scrim.isHidden = true
        addSubview(scrim)
        if let panel = webView.conversationPanel { addSubview(panel) }
        if let findBar = webView.findBar { addSubview(findBar) }
        scrim.addAction(
            UIAction { [weak webView] _ in webView?.workspace.request("agent", open: false) }, for: .touchUpInside)
        webView.workspace.onChange = { [weak self] in self?.setNeedsLayout() }
        // The document follows only docked input. The AI panel also needs the
        // local hardware-keyboard toolbar without reducing the reading canvas.
        keyboardLayoutGuide.followsUndockedKeyboard = true
        keyboardLayoutGuide.usesBottomSafeArea = false
        inputBoundary.isUserInteractionEnabled = false
        inputBoundary.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputBoundary)
        let preferredTop = inputBoundary.topAnchor.constraint(equalTo: bottomAnchor)
        preferredTop.priority = .defaultLow
        NSLayoutConstraint.activate([
            inputBoundary.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputBoundary.trailingAnchor.constraint(equalTo: trailingAnchor),
            inputBoundary.bottomAnchor.constraint(equalTo: bottomAnchor),
            inputBoundary.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            inputBoundary.topAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            preferredTop,
        ])
        keyboardLayoutGuide.setConstraints(
            [inputBoundary.topAnchor.constraint(lessThanOrEqualTo: keyboardLayoutGuide.topAnchor)],
            activeWhenAwayFrom: .top)
        // A guide can move without laying out its owning viewport. Give the
        // occupied region a real height so its own layout publishes that change.
        inputBoundary.didLayout = { [weak self] in self?.updateInputBottomInset() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil)
        for name in [UIResponder.keyboardWillChangeFrameNotification, UITextView.textDidBeginEditingNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(inputWillChange(_:)), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(webView:)") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Background snapshots temporarily resize the scene. Keep those sizes out
        // of the live document's viewport and composited scrolling layers.
        guard window?.windowScene?.activationState != .background else { return }
        layoutWorkspace()
    }

    private func updateInputBottomInset() {
        guard window?.windowScene?.activationState != .background else { return }
        let inset = max(0, bounds.maxY - inputBoundary.frame.minY)
        if webView.inputBottomInset != inset {
            webView.inputBottomInset = inset
            setNeedsLayout()
        }
    }

    private func layoutWorkspace() {
        let workspace = webView.workspace
        let layout = workspace.resolve(width: bounds.width)
        if let findBar = webView.findBar, !findBar.isHidden {
            let frame = Self.findFrame(
                in: bounds, documentLeading: layout.documentLeading, height: findBar.preferredHeight)
            findBar.bounds.size = frame.size
            findBar.center = CGPoint(x: frame.midX, y: frame.midY)
        }
        let changed = previousLayout != layout || previousBounds != bounds
        let panel = webView.conversationPanel
        let opening = workspace.agent && (!previousAgent || panel?.isHidden == true)
        let closing = !workspace.agent && previousAgent
        let bottom = max(
            webView.inputBottomInset > 0 ? webView.inputBottomInset + ReaderDesign.floatingGap : 0,
            layout.sheet ? 0 : safeAreaInsets.bottom + ReaderDesign.agentEdgeInset)
        let top = ReaderDesign.floatingInset - ReaderDesign.agentControlInset
        let panelFrame: CGRect
        if layout.sheet {
            let height = max(0, min(bounds.height * ReaderDesign.agentSheetFraction, bounds.height - bottom - 24))
            panelFrame = CGRect(x: 0, y: bounds.height - bottom - height, width: bounds.width, height: height)
        } else {
            panelFrame = CGRect(
                x: bounds.width - ReaderDesign.agentEdgeInset - layout.agentWidth, y: top,
                width: layout.agentWidth, height: max(0, bounds.height - bottom - top))
        }
        let targetDocument = CGRect(
            x: 0, y: 0, width: max(0, bounds.width - layout.reservedWidth), height: bounds.height)
        let geometryChanged = webView.frame != targetDocument || (panel != nil && previousPanelFrame != panelFrame)
        guard changed || geometryChanged || opening || closing else { return }
        let initialLayout = previousBounds.isEmpty
        previousAgent = workspace.agent
        previousPanelFrame = panelFrame
        previousLayout = layout
        previousBounds = bounds
        presentationRevision += 1
        let revision = presentationRevision
        panel?.sheet = layout.sheet
        panel?.bottomInset = layout.sheet && bottom == 0 ? safeAreaInsets.bottom : 0
        scrim.frame = bounds
        if opening && panel?.isHidden == true {
            panel?.frame = panelFrame
            panel?.isHidden = false
            panel?.alpha = 0
            panel?.transform =
                layout.sheet
                ? CGAffineTransform(translationX: 0, y: panelFrame.height) : CGAffineTransform(translationX: 24, y: 0)
        }
        if workspace.agent { scrim.isHidden = !layout.sheet }
        panel?.isUserInteractionEnabled = workspace.agent
        panel?.accessibilityViewIsModal = workspace.agent && layout.sheet
        if !workspace.agent { panel?.composer.setVisible(false) }
        workspace.project(layout, visible: panel?.isHidden == false)
        let updates = {
            self.webView.frame = targetDocument
            panel?.transform =
                workspace.agent
                ? .identity
                : (layout.sheet
                    ? CGAffineTransform(translationX: 0, y: panelFrame.height)
                    : CGAffineTransform(translationX: 24, y: 0))
            panel?.bounds.size = panelFrame.size
            panel?.center = CGPoint(x: panelFrame.midX, y: panelFrame.midY)
            panel?.alpha = workspace.agent ? 1 : 0
            self.scrim.alpha = workspace.agent && layout.sheet ? 1 : 0
            panel?.layoutIfNeeded()
            if workspace.agent { panel?.composer.setVisible(true) }
        }
        let finish: (Bool) -> Void = { [weak self] _ in
            guard let self, revision == self.presentationRevision else { return }
            if !workspace.agent {
                panel?.isHidden = true
                panel?.layer.removeAllAnimations()
                self.scrim.isHidden = true
            }
            workspace.project(layout, visible: workspace.agent)
        }
        if UIAccessibility.isReduceMotionEnabled || initialLayout {
            UIView.performWithoutAnimation(updates)
            finish(true)
        } else {
            UIView.animate(
                withDuration: opening || closing || changed
                    ? ReaderDesign.agentDuration : ReaderDesign.inputAvoidanceDuration,
                delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
                animations: updates, completion: finish)
        }
    }

    static func findFrame(in bounds: CGRect, documentLeading: CGFloat, height: CGFloat) -> CGRect {
        let inset = ReaderDesign.floatingInset
        let available = max(0, bounds.width - documentLeading - 2 * inset)
        let width = min(ReaderDesign.findWidth, available)
        return CGRect(x: bounds.maxX - inset - width, y: bounds.minY + inset, width: width, height: height)
    }

    @objc private func inputWillChange(_ notification: Notification) {
        guard currentInput != nil else { return }
        restoreInputTracking()
    }

    private var currentInput: UITextView? {
        guard let window, window.isKeyWindow, window.windowScene?.activationState != .background else { return nil }
        return focusedInput(in: self)
    }

    private func restoreInputTracking() {
        // System menus can overwrite the window's shared options while each
        // reader guide still reports true. Reassert the policy when reader
        // input starts or the system transitions its input interface, rather
        // than depending on the dismissal callback of an individual menu.
        keyboardLayoutGuide.followsUndockedKeyboard = false
        keyboardLayoutGuide.followsUndockedKeyboard = true
        window?.setNeedsLayout()
    }

    private func focusedInput(in view: UIView) -> UITextView? {
        if let input = view as? UITextView, input.isFirstResponder { return input }
        for child in view.subviews {
            if let input = focusedInput(in: child) { return input }
        }
        return nil
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === window?.windowScene else { return }
        if let input = currentInput {
            restoreInputTracking()
            // A minimized hardware-keyboard toolbar can reappear with an empty
            // system layout guide after backgrounding. Refresh the current input
            // interface without resigning focus or replacing the text view.
            input.reloadInputViews()
        }
        setNeedsLayout()
        layoutIfNeeded()
    }
}

@MainActor
final class ReaderContainer: UIView {
    private let viewport: ReaderViewport
    private let keyboardRegion = ReaderKeyboardRegion()

    init(webView: ReaderWKWebView) {
        viewport = ReaderViewport(webView: webView)
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        // UIKit shares undocked tracking within a window. All reader guides
        // must follow it; actual coverage decides whether to resize the document.
        keyboardLayoutGuide.followsUndockedKeyboard = true
        keyboardLayoutGuide.usesBottomSafeArea = false
        keyboardRegion.isUserInteractionEnabled = false
        keyboardRegion.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboardRegion)
        addSubview(viewport)
        // Keep an Auto Layout dependency on the keyboard even when the reading
        // viewport stays full size. Its vertical extent also tracks movement.
        NSLayoutConstraint.activate([
            keyboardRegion.leadingAnchor.constraint(equalTo: keyboardLayoutGuide.leadingAnchor),
            keyboardRegion.widthAnchor.constraint(equalTo: keyboardLayoutGuide.widthAnchor),
            keyboardRegion.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            keyboardRegion.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        keyboardRegion.didLayout = { [weak self] in self?.layoutReadingViewport() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutReadingViewport()
    }

    private func layoutReadingViewport() {
        let frame = Self.readingFrame(in: bounds, keyboard: keyboardLayoutGuide.layoutFrame)
        if viewport.frame != frame { viewport.frame = frame }
    }

    static func readingFrame(in bounds: CGRect, keyboard: CGRect) -> CGRect {
        guard keyboard.minX <= bounds.minX, keyboard.maxX >= bounds.maxX,
            keyboard.maxY >= bounds.maxY
        else { return bounds }
        var frame = bounds
        frame.size.height = max(0, min(bounds.height, keyboard.minY - bounds.minY))
        return frame
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(webView:)") }
}

@MainActor
private final class ReaderKeyboardRegion: UIView {
    var didLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        didLayout?()
    }
}
