import SwiftUI
import UIKit

/// Reader controls preserve each SF Symbol's natural optical metrics.
@MainActor
enum ReaderChromeSymbols {
    static func symbol(_ name: String, pointSize: CGFloat = ReaderDesign.readerChromeIcon) -> UIImage? {
        UIImage(
            systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
    }
}

/// All document chrome uses the document column's leading edge and one stride.
struct ReaderChromeLayout {
    let back: CGFloat
    let outline: CGFloat
    let close: CGFloat

    init(width: CGFloat, documentLeading: CGFloat, showsOutline: Bool, hasPrevious: Bool, agentOpen: Bool) {
        let inset = ReaderDesign.chromeInset
        let stride = ReaderDesign.hitTarget + ReaderDesign.floatingInset
        back = inset + documentLeading
        outline = inset + (hasPrevious && documentLeading == 0 ? stride : 0)
        if agentOpen, hasPrevious {
            close = max(back + stride, showsOutline ? outline + stride : 0)
        } else if agentOpen {
            let clearance = showsOutline ? ReaderDesign.hitTarget + 2 * ReaderDesign.floatingInset : 0
            close = inset + max(documentLeading, clearance)
        } else {
            close = max(inset, width - ReaderDesign.hitTarget - inset)
        }
    }
}

/// Search temporarily owns the header. Remove native glass controls as well as
/// their accessibility elements; session-owned navigation state stays intact.
struct ReaderChromeVisibility: ViewModifier {
    var hidden: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        Group {
            if !hidden { content.transition(.opacity) }
        }
        .allowsHitTesting(!hidden)
        .accessibilityHidden(hidden)
        .animation(reduceMotion ? nil : .easeOut(duration: ReaderDesign.contentDuration), value: hidden)
    }
}

/// A short wind-up, a leaning dash and a soft landing, retargeted from the current pose.
struct ReaderDocumentCloseMotion: ViewModifier {
    var destination: CGFloat
    var reduceMotion: Bool
    @State private var initialPose: Pose

    private struct Pose {
        var x: CGFloat
        var y: CGFloat = 0
        var tilt: Double = 0
        var stretch: CGFloat = 1
    }

    init(destination: CGFloat, reduceMotion: Bool) {
        self.destination = destination
        self.reduceMotion = reduceMotion
        _initialPose = State(initialValue: Pose(x: destination))
    }

    func body(content: Content) -> some View {
        if reduceMotion {
            content.offset(x: destination)
        } else {
            content.keyframeAnimator(initialValue: initialPose, trigger: destination) { view, pose in
                view
                    .scaleEffect(x: pose.stretch, y: 2 - pose.stretch)
                    .rotationEffect(.degrees(pose.tilt))
                    .offset(x: pose.x, y: pose.y)
            } keyframes: { pose in
                let direction: CGFloat = destination >= pose.x ? 1 : -1
                let windUp = ReaderDesign.documentCloseAnticipation
                let settle = ReaderDesign.documentCloseSettle
                let travel = ReaderDesign.documentCloseDuration - windUp - settle
                KeyframeTrack(\.x) {
                    CubicKeyframe(pose.x - direction * 6, duration: windUp, endVelocity: 0)
                    CubicKeyframe(destination + direction * 4, duration: travel, startVelocity: 0, endVelocity: 0)
                    CubicKeyframe(destination, duration: settle, startVelocity: 0, endVelocity: 0)
                }
                KeyframeTrack(\.y) {
                    CubicKeyframe(2, duration: windUp)
                    CubicKeyframe(-4, duration: travel * 0.5)
                    CubicKeyframe(0, duration: travel * 0.5)
                    CubicKeyframe(0, duration: settle, endVelocity: 0)
                }
                KeyframeTrack(\.tilt) {
                    CubicKeyframe(Double(-direction) * 8, duration: windUp)
                    CubicKeyframe(Double(direction) * 12, duration: travel * 0.45)
                    CubicKeyframe(Double(-direction) * 3, duration: travel * 0.55)
                    CubicKeyframe(0, duration: settle, endVelocity: 0)
                }
                KeyframeTrack(\.stretch) {
                    CubicKeyframe(1.06, duration: windUp)
                    CubicKeyframe(0.96, duration: travel * 0.45)
                    CubicKeyframe(1.02, duration: travel * 0.55)
                    CubicKeyframe(1, duration: settle, endVelocity: 0)
                }
            }
        }
    }
}

/// Keep a stable trailing anchor and animate each action along its own path.
/// Slots keep the same footprint when folding; the disclosure stays mounted at the end.
struct ReaderToolsLayout: Layout {
    var expansion: CGFloat

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = ReaderDesign.hitTarget + CGFloat(max(0, subviews.count - 1)) * stride
        return CGSize(width: min(width, proposal.width ?? width), height: ReaderDesign.hitTarget)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = max(1, subviews.count - 1)
        let step = min(stride, max(ReaderDesign.hitTarget, (bounds.width - ReaderDesign.hitTarget) / CGFloat(count)))
        for (index, subview) in subviews.enumerated() {
            let slot = CGFloat(subviews.count - 1 - index)
            subview.place(
                at: CGPoint(
                    x: bounds.maxX - ReaderDesign.hitTarget / 2 - slot * step * expansion,
                    y: bounds.midY),
                anchor: .center,
                proposal: ProposedViewSize(width: ReaderDesign.hitTarget, height: ReaderDesign.hitTarget))
        }
    }

    private var stride: CGFloat { ReaderDesign.hitTarget + ReaderDesign.floatingGap }
}

struct ReaderToolVisibility: ViewModifier {
    let expanded: Bool

    func body(content: Content) -> some View {
        ZStack {
            if expanded { content.transition(.opacity) }
        }
        .frame(width: ReaderDesign.hitTarget, height: ReaderDesign.hitTarget)
        .allowsHitTesting(expanded)
        .accessibilityHidden(!expanded)
    }
}

/// Shared SwiftUI controls follow system input geometry through native constraints.
struct ReaderFloatingControls<Content: View>: UIViewControllerRepresentable {
    var expanded: Bool
    @ViewBuilder var content: Content

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(content: content, expanded: expanded)
        controller.surface.reduceMotion = context.environment.accessibilityReduceMotion
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.surface.expanded = expanded
        controller.surface.reduceMotion = context.environment.accessibilityReduceMotion
        // Each hosting root supplies its own environment.
        // Forward the animation transaction without replacing the entire environment.
        withTransaction(context.transaction) { controller.host.rootView = content }
    }

    @MainActor
    final class Controller: UIViewController {
        fileprivate let host: UIHostingController<Content>
        fileprivate let surface = ReaderControlsSurface()
        init(content: Content, expanded: Bool) {
            host = UIHostingController(rootView: content)
            surface.expanded = expanded
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Use init(content:expanded:)") }

        override func loadView() { view = surface }

        override func viewDidLoad() {
            super.viewDidLoad()
            host.sizingOptions = .intrinsicContentSize
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)

            let safeArea = view.safeAreaLayoutGuide
            let keyboard = view.keyboardLayoutGuide
            keyboard.followsUndockedKeyboard = true
            keyboard.usesBottomSafeArea = false
            let inset = ReaderDesign.floatingInset
            let preferredBottom = host.view.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -inset)
            preferredBottom.priority = .defaultLow
            NSLayoutConstraint.activate([
                host.view.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -inset),
                host.view.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: inset),
                host.view.topAnchor.constraint(greaterThanOrEqualTo: safeArea.topAnchor, constant: inset),
                host.view.bottomAnchor.constraint(lessThanOrEqualTo: safeArea.bottomAnchor, constant: -inset),
                preferredBottom,
            ])
            // A floating keyboard near the top must not push the controls offscreen.
            // Vertical avoidance is independent of the mini toolbar's horizontal edge.
            keyboard.setConstraints(
                [
                    host.view.bottomAnchor.constraint(
                        lessThanOrEqualTo: keyboard.topAnchor, constant: -ReaderDesign.floatingGap)
                ],
                activeWhenAwayFrom: .top)
        }
    }
}

/// The full-size positioning surface must leave document touches and scrolling alone.
@MainActor
final class ReaderControlsSurface: UIView {
    var expanded = false
    var reduceMotion = false

    override func layoutSubviews() {
        // Floating hardware-keyboard controls can update their guide in separate,
        // unanimated passes. Preserve system transitions; animate only those gaps.
        guard window != nil, subviews.first?.frame.isEmpty == false,
            UIView.inheritedAnimationDuration == 0, !reduceMotion
        else {
            super.layoutSubviews()
            return
        }
        UIView.animate(
            withDuration: ReaderDesign.inputAvoidanceDuration, delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) {
            super.layoutSubviews()
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !expanded, let controls = subviews.first {
            // A transparent hosting view can still consume touches. Limit its
            // collapsed input region to the disclosure without resizing the layout.
            let disclosure = CGRect(
                x: controls.bounds.maxX - ReaderDesign.hitTarget, y: controls.bounds.minY,
                width: ReaderDesign.hitTarget, height: controls.bounds.height)
            guard disclosure.contains(controls.convert(point, from: self)) else { return nil }
        }
        let target = super.hitTest(point, with: event)
        return target === self ? nil : target
    }
}

/// SwiftUI owns the symbol and motion; UIKit only owns the stable menu interaction.
struct ReaderMoreMenu: View {
    var iconSize: CGFloat
    var openModelSettings: () -> Void

    var body: some View {
        ZStack {
            Image(systemName: "ellipsis")
                .font(.system(size: iconSize))
                .accessibilityHidden(true)
            ReaderMoreMenuButton(openModelSettings: openModelSettings)
                .frame(width: ReaderDesign.hitTarget, height: ReaderDesign.hitTarget)
        }
    }
}

/// Fixed reader actions use an eager menu so an in-flight touch keeps its target.
private struct ReaderMoreMenuButton: UIViewRepresentable {
    var openModelSettings: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(openModelSettings: openModelSettings) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityLabel = String(localized: "More")
        button.accessibilityIdentifier = "More"
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            UIAction(title: String(localized: "Model Settings"), image: UIImage(systemName: "slider.horizontal.3")) {
                [weak coordinator = context.coordinator] _ in
                coordinator?.openModelSettings()
            }
        ])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.openModelSettings = openModelSettings
        if button.isEnabled != context.environment.isEnabled { button.isEnabled = context.environment.isEnabled }
    }

    @MainActor
    final class Coordinator {
        var openModelSettings: () -> Void

        init(openModelSettings: @escaping () -> Void) { self.openModelSettings = openModelSettings }
    }
}
