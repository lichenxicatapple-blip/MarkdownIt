import UIKit
import UIKit.UIGestureRecognizerSubclass
import WebKit

@MainActor
final class ReaderPencilInteraction: NSObject, UIGestureRecognizerDelegate {
    struct Region: Decodable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let fontSize: CGFloat
        let lineHeight: CGFloat
        let textY: CGFloat
        let overflow: Bool
        var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
    enum Intent: Equatable { case waiting, underline, scroll }

    /// Spatial hysteresis follows the text's scale. Once recognized, a stroke
    /// keeps its purpose until lift; its later waves never become scrolling.
    static func intent(translation: CGPoint, region: Region?) -> Intent {
        guard let region, !region.overflow else { return .scroll }
        if abs(translation.y) > region.lineHeight * ReaderDesign.pencilVerticalEscape { return .scroll }
        if abs(translation.x) >= region.fontSize * ReaderDesign.pencilHorizontalIntent { return .underline }
        return .waiting
    }

    static func region(at point: CGPoint, in regions: [Region]) -> Region? {
        regions.filter { $0.bounds.contains(point) }.min {
            abs($0.bounds.midY - point.y) < abs($1.bounds.midY - point.y)
        }
    }

    private weak var webView: ReaderWKWebView?
    private var regions: [Region] = []
    private var textY: CGFloat = 0
    private var identifier = ""
    private var sequence = 0
    private lazy var gesture: PencilUnderlineGesture = {
        let gesture = PencilUnderlineGesture(target: self, action: #selector(changed(_:)))
        gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        gesture.delegate = self
        gesture.name = "DocumentUnderline"
        gesture.region = { [weak self] point in
            guard let self, let webView = self.webView else { return nil }
            let content = webView.scrollView.convert(point, from: webView)
            return Self.region(at: content, in: self.regions)
        }
        return gesture
    }()
    var enabled: (() -> Bool)?
    var onBegin: (() -> Void)?
    var send: (([String: Any]) -> Void)?

    init(webView: ReaderWKWebView) {
        self.webView = webView
        super.init()
        webView.addGestureRecognizer(gesture)
        webView.scrollView.panGestureRecognizer.require(toFail: gesture)
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        if !webView.scrollView.panGestureRecognizer.allowedTouchTypes.contains(pencil) {
            webView.scrollView.panGestureRecognizer.allowedTouchTypes.append(pencil)
        }
    }

    func update(_ regions: [Region]) {
        self.regions = regions.filter {
            [$0.x, $0.y, $0.width, $0.height, $0.textY, $0.fontSize, $0.lineHeight].allSatisfy(\.isFinite)
                && $0.width > 0 && $0.height > 0 && $0.fontSize > 0 && $0.lineHeight > 0
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard enabled?() == true, let webView, touch.type == .pencil else { return false }
        var view = touch.view
        while let current = view, current !== webView {
            if current is AnnotationCardView || current is UITextView || current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    @objc private func changed(_ gesture: PencilUnderlineGesture) {
        guard let webView else { return }
        let phase: String
        switch gesture.state {
        case .began:
            identifier = UUID().uuidString
            sequence = 0
            onBegin?()
            if let region = gesture.line {
                let content = webView.scrollView.convert(gesture.start, from: webView)
                textY = webView.convert(CGPoint(x: content.x, y: region.textY), from: webView.scrollView).y
            }
            phase = "update"
        case .changed: phase = "update"
        case .ended: phase = "commit"
        case .cancelled: phase = "cancel"
        default: return
        }
        sequence += 1
        send?([
            "id": identifier, "sequence": sequence, "phase": phase,
            "start": ["x": gesture.start.x, "y": textY], "point": ["x": gesture.point.x, "y": textY],
        ])
    }

    func detach() {
        webView?.removeGestureRecognizer(gesture)
        regions.removeAll()
        enabled = nil
        onBegin = nil
        send = nil
    }
}

/// Holding .possible is a normal recognizer dependency, not a delayed callback.
/// WebKit's pan receives the original touch sequence when vertical intent wins.
@MainActor
private final class PencilUnderlineGesture: UIGestureRecognizer {
    var region: ((CGPoint) -> ReaderPencilInteraction.Region?)?
    private(set) var start = CGPoint.zero
    private(set) var point = CGPoint.zero
    private(set) var line: ReaderPencilInteraction.Region?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first, touch.type == .pencil else {
            state = .failed
            return
        }
        start = touch.location(in: view)
        point = start
        line = region?(start)
        if line == nil || line?.overflow == true { state = .failed }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        point = touch.location(in: view)
        if state == .possible {
            switch ReaderPencilInteraction.intent(
                translation: CGPoint(x: point.x - start.x, y: point.y - start.y), region: line)
            {
            case .waiting: break
            case .underline: state = .began
            case .scroll: state = .failed
            }
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { point = touch.location(in: view) }
        state = state == .began || state == .changed ? .ended : .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func reset() {
        super.reset()
        line = nil
        start = .zero
        point = .zero
    }
}
