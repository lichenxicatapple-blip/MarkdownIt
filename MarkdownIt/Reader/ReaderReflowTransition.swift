import UIKit

/// Updates the live document width on display frames. Animating only a UIView's
/// presentation bounds would give WebKit its final width before the motion begins.
@MainActor
final class ReaderReflowTransition {
    @MainActor
    private final class Driver: NSObject {
        weak var owner: ReaderReflowTransition?

        @objc func step(_ link: CADisplayLink) {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.update(at: link.targetTimestamp)
        }
    }

    private weak var view: UIView?
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var duration: TimeInterval = 0
    private var initialWidth: CGFloat = 0
    private(set) var targetWidth: CGFloat?
    var onFinish: (() -> Void)?
    var isActive: Bool { targetWidth != nil }

    isolated deinit { displayLink?.invalidate() }

    func animate(_ view: UIView, to width: CGFloat, duration: TimeInterval) {
        guard view.frame.width != width, duration > 0 else {
            cancel()
            UIView.performWithoutAnimation { view.frame.size.width = width }
            return
        }
        self.view = view
        initialWidth = view.frame.width
        targetWidth = width
        self.duration = duration
        startedAt = CACurrentMediaTime()
        if displayLink == nil {
            let driver = Driver()
            driver.owner = self
            let link = CADisplayLink(target: driver, selector: #selector(Driver.step(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    private func update(at timestamp: CFTimeInterval) {
        guard let view, let targetWidth else {
            cancel()
            return
        }
        let fraction = min(1, max(0, (timestamp - startedAt) / duration))
        let progress = CGFloat((1 - cos(.pi * fraction)) / 2)
        UIView.performWithoutAnimation {
            view.frame.size.width = initialWidth + (targetWidth - initialWidth) * progress
        }
        if fraction == 1 { cancel() }
    }

    func cancel() {
        guard isActive else { return }
        targetWidth = nil
        view = nil
        displayLink?.invalidate()
        displayLink = nil
        onFinish?()
    }
}
