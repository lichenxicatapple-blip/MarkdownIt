import UIKit
import WebKit

struct AnnotationRequest: Codable, Sendable {
    struct Rect: Codable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
    var id: UUID?
    let token: String
    let revision: Int
    let ranges: [AnnotationRange]
    let anchor: AnnotationRange
    var rect: Rect
    var create: Bool = false
}

/// Native card content attaches to the same UIScrollView as WebKit's document.
/// Scrolling moves the existing view; only reflow updates its semantic anchor.
@MainActor
final class ReaderAnnotationHost: NSObject, UIGestureRecognizerDelegate, UIAdaptivePresentationControllerDelegate {
    struct Recovery: Codable, Sendable {
        var request: AnnotationRequest
        let text: String
        let selection: NSRange
        let focused: Bool
    }
    func checkpoint() -> Recovery? {
        guard let request, let card else { return nil }
        return Recovery(
            request: request, text: card.textView.text, selection: card.textView.selectedRange,
            focused: card.textView.isFirstResponder)
    }
    func restore(_ recovery: Recovery) {
        var value = recovery.request
        value.create = false
        show(value)
        card?.restoreDraft(text: recovery.text, selection: recovery.selection)
        if recovery.focused { card?.textView.becomeFirstResponder() }
    }

    private weak var webView: ReaderWKWebView?
    private let session: ReaderSession
    private let menu: ReaderActionMenu
    private var request: AnnotationRequest?
    private(set) var card: AnnotationCardView?
    private var sheet: UIViewController?
    private var contentAnchor: CGRect?
    private var offset = CGPoint.zero
    private var above = false
    private var observations: [NSKeyValueObservation] = []
    private var outsideID: UUID?
    private lazy var outsideTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(tappedOutside))
        gesture.cancelsTouchesInView = false
        gesture.delegate = self
        return gesture
    }()
    var call: (@MainActor (String, [String: Any]) async -> Void)?
    var hasUnsavedChanges: Bool { card?.hasUnsavedChanges == true }

    init(session: ReaderSession, webView: ReaderWKWebView, menu: ReaderActionMenu) {
        self.session = session
        self.webView = webView
        self.menu = menu
        super.init()
        webView.addGestureRecognizer(outsideTap)
        observations.append(
            webView.scrollView.observe(\.contentOffset, options: []) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.checkVisibility() }
            })
        observations.append(
            webView.observe(\.bounds, options: []) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateViewport() }
            })
    }

    func show(_ value: AnnotationRequest) {
        guard value.token == session.documentToken, session.mode == "preview", !session.isClosingDocument,
            value.revision == session.bridge?.sourceEditor.history.revision,
            !value.ranges.isEmpty, value.ranges.allSatisfy(\.isValid),
            [value.rect.x, value.rect.y, value.rect.width, value.rect.height].allSatisfy(\.isFinite),
            !hasUnsavedChanges
        else { return }
        dismiss(force: true)
        request = value
        let record = value.id.flatMap { id in session.annotations.visible.first { $0.id == id } }
        if value.id != nil && record == nil {
            request = nil
            return
        }
        if let record, record.note.isEmpty, !value.create {
            let add = UIAction(title: String(localized: "Add Annotation…"), image: UIImage(systemName: "text.bubble")) {
                [weak self] _ in
                self?.presentCard(record: record, focus: true)
            }
            let remove = UIAction(
                title: String(localized: "Remove Underline"), image: UIImage(systemName: "underline"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.confirm(title: String(localized: "Remove Underline?"), action: String(localized: "Remove")) {
                    [weak self] in
                    await self?.setUnderline(false)
                }
            }
            menu.show(
                id: record.id.uuidString, at: CGPoint(x: value.rect.cgRect.midX, y: value.rect.cgRect.midY),
                actions: [add, remove])
        } else {
            presentCard(record: record, focus: value.create)
        }
    }

    private var presenter: UIViewController? {
        var responder: UIResponder? = webView
        while let current = responder {
            if let controller = current as? UIViewController {
                var top = controller
                while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
                return top
            }
            responder = current.next
        }
        return nil
    }

    private var available: CGRect {
        guard let webView else { return .zero }
        var rect = webView.bounds.inset(by: webView.safeAreaInsets)
        rect.size.height = max(0, rect.height - webView.inputBottomInset)
        return rect.insetBy(dx: ReaderDesign.annotationGap, dy: ReaderDesign.annotationGap)
    }

    private func presentCard(record: ReadingAnnotation?, focus: Bool) {
        guard let request, let webView, request.token == session.documentToken else { return }
        menu.dismiss()
        let card = AnnotationCardView(
            note: record?.note ?? "", underlined: record?.underlined == true, existing: record?.note.isEmpty == false)
        self.card = card
        webView.annotationView = card.textView
        card.onCancel = { [weak self] in self?.dismiss(force: true) }
        card.onDone = { [weak self] note in
            guard let self else { return }
            Task { if await self.save(note: note) { self.dismiss(force: true) } }
        }
        card.onUnderline = { [weak self] in
            guard let self, let id = self.request?.id,
                let record = self.session.annotations.visible.first(where: { $0.id == id })
            else { return }
            if record.underlined {
                self.confirm(title: String(localized: "Remove Underline?"), action: String(localized: "Remove")) {
                    [weak self] in await self?.setUnderline(false)
                }
            } else {
                Task { await self.setUnderline(true) }
            }
        }
        card.onDelete = { [weak self] in
            self?.confirm(title: String(localized: "Delete Annotation?"), action: String(localized: "Delete")) {
                [weak self] in
                guard let self else { return }
                if await self.save(note: "") { self.dismiss(force: true) }
            }
        }
        card.onChange = { [weak self] in
            guard let self else { return }
            self.sheet?.isModalInPresentation = self.hasUnsavedChanges
            self.session.requestCheckpoint()
            self.updateViewport()
        }
        let area = available
        let size = card.fittingSize(width: min(ReaderDesign.annotationWidth, area.width), maximumHeight: area.height)
        let minimum = ReaderDesign.hitTarget * 2 + ReaderDesign.annotationMinimumEditor + ReaderDesign.annotationBodyGap
        let anchor = request.rect.cgRect
        let room = max(area.maxY - anchor.maxY, anchor.minY - area.minY) - ReaderDesign.annotationGap
        if room < min(size.height, minimum), let presenter {
            let controller = AnnotationSheetController(card: card)
            controller.modalPresentationStyle = .pageSheet
            if let sheet = controller.sheetPresentationController {
                let fitting = UISheetPresentationController.Detent.custom { context in
                    let size = card.fittingSize(
                        width: presenter.view.bounds.width, maximumHeight: context.maximumDetentValue)
                    return min(context.maximumDetentValue, size.height + presenter.view.safeAreaInsets.bottom)
                }
                sheet.detents = [fitting, .large()]
                sheet.prefersGrabberVisible = true
            }
            sheet = controller
            controller.presentationController?.delegate = self
            presenter.present(controller, animated: !UIAccessibility.isReduceMotionEnabled) {
                if focus { card.textView.becomeFirstResponder() }
            }
        } else {
            let anchor = request.rect.cgRect
            contentAnchor = webView.convert(anchor, to: webView.scrollView)
            let belowRoom = area.maxY - anchor.maxY
            let aboveRoom = anchor.minY - area.minY
            above = belowRoom < size.height + ReaderDesign.annotationGap && aboveRoom > belowRoom
            let x = min(max(anchor.midX - size.width / 2, area.minX), max(area.minX, area.maxX - size.width))
            let y = min(
                max(
                    above
                        ? anchor.minY - size.height - ReaderDesign.annotationGap
                        : anchor.maxY + ReaderDesign.annotationGap, area.minY), max(area.minY, area.maxY - size.height))
            offset = CGPoint(x: x - anchor.midX, y: y - anchor.minY)
            card.frame = webView.convert(CGRect(origin: CGPoint(x: x, y: y), size: size), to: webView.scrollView)
            webView.scrollView.addSubview(card)
            card.layoutIfNeeded()
            card.setArrow(x: anchor.midX - x, below: above)
            if !UIAccessibility.isReduceMotionEnabled {
                card.alpha = 0
                card.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
                UIView.animate(withDuration: ReaderDesign.contentDuration) {
                    card.alpha = 1
                    card.transform = .identity
                }
            }
            if focus { card.textView.becomeFirstResponder() }
        }
        Task {
            await self.call?(
                "annotationPresentation",
                [
                    "id": request.id?.uuidString ?? "",
                    "anchor": ["start": request.anchor.start, "end": request.anchor.end],
                    "ranges": request.ranges.map { ["start": $0.start, "end": $0.end] },
                ])
        }
    }

    private func save(note: String? = nil, underlined: Bool? = nil) async -> Bool {
        guard let request else { return false }
        card?.setBusy(true)
        defer { card?.setBusy(false) }
        return await session.setAnnotation(
            ranges: request.ranges, underlined: underlined, note: note, id: request.id, token: request.token,
            sourceRevision: request.revision)
    }

    private func setUnderline(_ value: Bool) async {
        guard await save(underlined: value) else { return }
        card?.setUnderlined(value)
        if card == nil { dismiss(force: true) }
    }

    private func confirm(title: String, action: String, perform: @escaping @MainActor () async -> Void) {
        menu.dismiss()
        guard let presenter else { return }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: action, style: .destructive) { _ in
                presenter.dismiss(animated: true) { Task { await perform() } }
            })
        presenter.present(alert, animated: true)
    }

    func updateAnchor(_ rect: AnnotationRequest.Rect) {
        guard let request, let card, sheet == nil, let webView,
            [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite)
        else { return }
        self.request?.rect = rect
        let anchor = rect.cgRect
        contentAnchor = webView.convert(anchor, to: webView.scrollView)
        var frame = CGRect(
            origin: CGPoint(x: anchor.midX + offset.x, y: anchor.minY + offset.y), size: card.bounds.size)
        if card.hasUnsavedChanges {
            frame.origin.y = min(max(frame.minY, available.minY), max(available.minY, available.maxY - frame.height))
        }
        card.frame = webView.convert(frame, to: webView.scrollView)
        card.setArrow(x: anchor.midX - frame.minX, below: above)
        if request.token != session.documentToken { dismiss(force: true) }
    }

    func updateViewport() {
        guard let request, let card, sheet == nil, let webView else { return }
        let current = webView.convert(card.frame, from: webView.scrollView)
        let area = available
        let size = card.fittingSize(width: min(ReaderDesign.annotationWidth, area.width), maximumHeight: area.height)
        var frame = CGRect(origin: current.origin, size: size)
        if hasUnsavedChanges || card.textView.isFirstResponder {
            frame.origin.x = min(max(frame.minX, area.minX), max(area.minX, area.maxX - size.width))
            frame.origin.y = min(max(frame.minY, area.minY), max(area.minY, area.maxY - size.height))
            let anchor = contentAnchor.map { webView.convert($0, from: webView.scrollView) } ?? request.rect.cgRect
            offset = CGPoint(x: frame.minX - anchor.midX, y: frame.minY - anchor.minY)
        }
        card.frame = webView.convert(frame, to: webView.scrollView)
        card.setNeedsLayout()
        checkVisibility()
    }

    private func checkVisibility() {
        guard let card, sheet == nil, let webView, !hasUnsavedChanges, !card.textView.isFirstResponder else { return }
        let bleed = card.layer.shadowRadius * 2 + abs(card.layer.shadowOffset.height)
        let paint = webView.convert(card.frame.insetBy(dx: -bleed, dy: -bleed), from: webView.scrollView)
        if !webView.bounds.intersects(paint) { dismiss(force: true, animated: false) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let card, !hasUnsavedChanges, sheet == nil, let touched = touch.view, !touched.isDescendant(of: card)
        else { return false }
        outsideID = request?.id
        return true
    }
    @objc private func tappedOutside() { if outsideID == request?.id { dismiss() } }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        sheet = nil
        dismiss(force: true)
    }

    func dismiss(force: Bool = false, animated: Bool = true) {
        guard force || !hasUnsavedChanges else { return }
        menu.dismiss()
        card?.endEditing(true)
        card?.removeFromSuperview()
        card = nil
        webView?.annotationView = nil
        request = nil
        if let sheet {
            self.sheet = nil
            sheet.dismiss(animated: animated)
        }
        Task { await self.call?("annotationPresentation", [:]) }
        session.requestCheckpoint()
    }

    func detach() {
        dismiss(force: true, animated: false)
        observations.removeAll()
        webView?.removeGestureRecognizer(outsideTap)
        call = nil
    }
}

@MainActor
private final class AnnotationSheetController: UIViewController {
    private let card: AnnotationCardView
    init(card: AnnotationCardView) {
        self.card = card
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = UIView()
        view.backgroundColor = ReaderDesign.annotationPaper
        view.addSubview(card)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        card.frame = view.bounds.inset(
            by: UIEdgeInsets(top: view.safeAreaInsets.top, left: 0, bottom: view.safeAreaInsets.bottom, right: 0))
        card.layer.shadowOpacity = 0
        card.layer.borderWidth = 0
        card.setArrow(x: 0, below: false, hidden: true)
    }
}
