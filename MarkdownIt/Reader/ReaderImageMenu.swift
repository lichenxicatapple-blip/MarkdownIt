import UIKit

/// A tap exposes the image's AI action through UIKit. WebKit keeps ownership of
/// long presses, image recognition, copying and sharing.
@MainActor
final class ReaderImageMenu {
    private struct Selection {
        let id: String
        let token: String
        let reference: AgentAttachment
        let point: CGPoint
    }
    private let menu: ReaderActionMenu
    private var selection: Selection?
    var onAsk: ((AgentAttachment, String, CGPoint) -> Void)?
    var onDismiss: ((String) -> Void)?

    init(menu: ReaderActionMenu) { self.menu = menu }

    func show(id: String, token: String, reference: AgentAttachment, point: CGPoint) {
        guard reference.images?.isEmpty == false, reference.mode == "preview" else { return }
        let selection = Selection(id: id, token: token, reference: reference, point: point)
        self.selection = selection
        let ask = UIAction(title: String(localized: "Reference in AI Chat…"), image: UIImage(systemName: "bubble.left"))
        {
            [weak self] _ in
            self?.onAsk?(selection.reference, selection.token, selection.point)
        }
        menu.show(id: id, at: point, actions: [ask]) { [weak self] in
            if self?.selection?.id == id { self?.selection = nil }
            self?.onDismiss?(id)
        }
    }

    func dismiss() {
        menu.dismiss()
        selection = nil
    }

    func detach() {
        dismiss()
        onAsk = nil
        onDismiss = nil
    }
}
