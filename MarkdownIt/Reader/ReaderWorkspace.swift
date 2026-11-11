import UIKit

/// The only responsive layout policy for document, outline and conversation.
@MainActor
final class ReaderWorkspace {
    var onChange: (() -> Void)?
    var onProjection: (([String: Any]) -> Void)?
    var onPresentation: ((Bool, Bool, Bool, CGFloat) -> Void)?
    private(set) var agent = false
    private(set) var outline = false
    private(set) var hasOutline = false
    private(set) var mode = "preview"
    private var lastActivePanel = "outline"
    private var width: CGFloat = 0
    private var revision = 0
    private var initializedOutline = false
    private var closeWaiters: [CheckedContinuation<Bool, Never>] = []
    private(set) var visible = false

    struct Layout: Equatable {
        var outlineOpen: Bool
        var agentOpen: Bool
        var sheet: Bool
        var overlay: Bool
        var coexist: Bool
        var agentWidth: CGFloat
        var documentLeading: CGFloat
        var reservedWidth: CGFloat
    }
    var recovery: [String: Any] { ["agent": agent, "outline": outline, "lastActivePanel": lastActivePanel] }
    func load(mode: String, recovery: [String: Any]?) {
        resolveWaiters(false)
        self.mode = mode
        agent = recovery?["agent"] as? Bool ?? false
        outline = recovery?["outline"] as? Bool ?? false
        initializedOutline = recovery != nil
        lastActivePanel = recovery?["lastActivePanel"] as? String ?? "outline"
        hasOutline = false
        onChange?()
    }
    func update(mode: String, hasOutline: Bool) {
        let changed = self.mode != mode || self.hasOutline != hasOutline
        self.mode = mode
        self.hasOutline = hasOutline
        if !initializedOutline, hasOutline, width > 0 {
            outline = width >= ReaderDesign.documentMinimumWidth + ReaderDesign.outlineWidth
            initializedOutline = true
        }
        if changed { onChange?() }
    }
    func interact(_ panel: String) { lastActivePanel = panel }
    func request(_ panel: String, open: Bool) {
        if open { interact(panel) }
        if panel == "agent" { agent = open } else if panel == "outline" { outline = open }
        if agent { resolveWaiters(false) }
        onChange?()
    }
    func resolve(width: CGFloat) -> Layout {
        self.width = width
        let minimum = ReaderDesign.documentMinimumWidth
        let agentMinimum = ReaderDesign.agentMinimumWidth
        let edge = ReaderDesign.agentEdgeInset
        let outlineWidth = ReaderDesign.outlineWidth
        let sheet = width < minimum + agentMinimum + edge
        let coexist = width >= minimum + agentMinimum + edge + outlineWidth
        if agent && outline && hasOutline && mode == "preview" && !coexist {
            if lastActivePanel == "outline" { agent = false } else { outline = false }
        }
        let showOutline = outline && hasOutline && mode == "preview"
        let overlay = width < minimum + outlineWidth
        let leading = showOutline && !overlay ? outlineWidth : 0
        let available = width - minimum - edge - leading
        let panelWidth = min(
            max(width * ReaderDesign.agentWidthFraction, agentMinimum),
            min(ReaderDesign.agentWidth, max(agentMinimum, available)))
        return Layout(
            outlineOpen: showOutline, agentOpen: agent, sheet: sheet, overlay: overlay, coexist: coexist,
            agentWidth: panelWidth, documentLeading: leading,
            reservedWidth: agent && !sheet ? panelWidth + edge : 0)
    }
    func project(_ layout: Layout, visible: Bool) {
        self.visible = visible
        revision += 1
        onProjection?([
            "compact": width <= ReaderDesign.compactWindow, "revision": revision, "agent": agent, "outline": outline,
            "sheet": layout.sheet,
            "overlay": layout.overlay, "coexist": layout.coexist, "modal": visible && layout.sheet,
        ])
        onPresentation?(agent, visible, visible && layout.sheet, layout.documentLeading)
        if !visible { resolveWaiters(true) }
    }
    func refreshProjection() {
        guard width > 0 else { return }
        project(resolve(width: width), visible: visible)
    }
    func waitUntilClosed() async -> Bool {
        if agent { return false }
        if !visible { return true }
        return await withCheckedContinuation { closeWaiters.append($0) }
    }
    private func resolveWaiters(_ value: Bool) {
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: value) }
    }
}
