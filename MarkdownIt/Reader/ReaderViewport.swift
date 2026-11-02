import UIKit
import WebKit

extension WKWebView {
    /// Native responders must stay outside WebKit's keyboard/responder hierarchy.
    func hostNativeInput(_ input: UIView, aboveWebContent: Bool) -> UIView? {
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
    private let composerBoundary = UILayoutGuide()

    init(webView: ReaderWKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .systemBackground
        webView.autoresizingMask = []
        addSubview(webView)
        // The document follows only docked input. The composer also needs the
        // local hardware-keyboard toolbar without reducing the reading canvas.
        keyboardLayoutGuide.followsUndockedKeyboard = true
        keyboardLayoutGuide.usesBottomSafeArea = false
        addLayoutGuide(composerBoundary)
        let preferredBottom = composerBoundary.bottomAnchor.constraint(equalTo: bottomAnchor)
        preferredBottom.priority = .defaultLow
        NSLayoutConstraint.activate([
            composerBoundary.leadingAnchor.constraint(equalTo: leadingAnchor),
            composerBoundary.trailingAnchor.constraint(equalTo: trailingAnchor),
            composerBoundary.heightAnchor.constraint(equalToConstant: 0),
            composerBoundary.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            composerBoundary.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            preferredBottom,
        ])
        keyboardLayoutGuide.setConstraints(
            [composerBoundary.bottomAnchor.constraint(lessThanOrEqualTo: keyboardLayoutGuide.topAnchor)],
            activeWhenAwayFrom: .top)
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
        webView.inputBottomInset = max(0, bounds.maxY - composerBoundary.layoutFrame.maxY)
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === window?.windowScene else { return }
        setNeedsLayout()
        layoutIfNeeded()
    }
}

@MainActor
final class ReaderContainer: UIView {
    init(webView: ReaderWKWebView) {
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        // UIKit follows docked keyboards and returns to the view's bottom for
        // undocked input, including floating keyboards and hardware-keyboard UI.
        keyboardLayoutGuide.followsUndockedKeyboard = false
        keyboardLayoutGuide.usesBottomSafeArea = false
        let viewport = ReaderViewport(webView: webView)
        viewport.translatesAutoresizingMaskIntoConstraints = false
        addSubview(viewport)
        NSLayoutConstraint.activate([
            viewport.topAnchor.constraint(equalTo: topAnchor),
            viewport.leadingAnchor.constraint(equalTo: leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: trailingAnchor),
            viewport.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(webView:)") }
}
