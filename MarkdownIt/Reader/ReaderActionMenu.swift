import UIKit
import WebKit

/// One native interaction host for document-image and annotation actions. Keeping
/// it off WebKit's content view preserves WebKit's own selection and image menus.
@MainActor
final class ReaderActionMenu: NSObject, @MainActor UIEditMenuInteractionDelegate {
    private let host = UIView()
    private weak var webView: WKWebView?
    private lazy var interaction = UIEditMenuInteraction(delegate: self)
    private var actions: [UIMenuElement] = []
    private var identifier: String?
    private var onDismiss: (() -> Void)?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
        host.frame = webView.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.isUserInteractionEnabled = false
        host.accessibilityElementsHidden = true
        webView.addSubview(host)
        host.addInteraction(interaction)
    }

    func show(id: String, at point: CGPoint, actions: [UIMenuElement], onDismiss: (() -> Void)? = nil) {
        guard let webView, webView.window != nil, point.x.isFinite, point.y.isFinite else { return }
        dismiss()
        identifier = id
        self.actions = actions
        self.onDismiss = onDismiss
        let point = CGPoint(
            x: min(max(point.x, webView.bounds.minX), webView.bounds.maxX),
            y: min(max(point.y, webView.bounds.minY), webView.bounds.maxY))
        interaction.presentEditMenu(
            with: UIEditMenuConfiguration(identifier: id as NSString, sourcePoint: host.convert(point, from: webView)))
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard configuration.identifier as? String == identifier else { return nil }
        return UIMenu(children: actions)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: any UIEditMenuInteractionAnimating
    ) {
        guard configuration.identifier as? String == identifier else { return }
        finish()
    }

    private func finish() {
        identifier = nil
        actions = []
        let action = onDismiss
        onDismiss = nil
        action?()
    }

    func dismiss() {
        interaction.dismissMenu()
        finish()
    }
    func detach() {
        dismiss()
        host.removeInteraction(interaction)
        host.removeFromSuperview()
    }
}
