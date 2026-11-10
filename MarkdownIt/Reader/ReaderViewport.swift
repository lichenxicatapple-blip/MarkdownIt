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

    init(webView: ReaderWKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .systemBackground
        webView.autoresizingMask = []
        addSubview(webView)
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(webView:)") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Background snapshots temporarily resize the scene. Keep those sizes out
        // of the live document's viewport and composited scrolling layers.
        guard window?.windowScene?.activationState != .background else { return }
        if webView.frame != bounds { webView.frame = bounds }
        updateInputBottomInset()
    }

    private func updateInputBottomInset() {
        guard window?.windowScene?.activationState != .background else { return }
        webView.inputBottomInset = max(0, bounds.maxY - inputBoundary.frame.minY)
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === window?.windowScene else { return }
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
