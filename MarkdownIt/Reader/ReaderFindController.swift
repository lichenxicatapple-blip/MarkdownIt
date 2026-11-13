import UIKit

/// One read-only system find navigator. Foundation searches either the working
/// buffer or article-only DOM text; TextKit and CSS render temporary highlights.
@MainActor
final class ReaderFindController: NSObject, UIFindInteractionDelegate, @MainActor UITextSearching {
    private final class Position: UITextPosition {
        let offset: Int
        init(_ offset: Int) { self.offset = offset }
    }

    private final class Range: UITextRange {
        let value: NSRange
        init(_ value: NSRange) { self.value = value }
        override var start: UITextPosition { Position(value.location) }
        override var end: UITextPosition { Position(NSMaxRange(value)) }
        override var isEmpty: Bool { value.length == 0 }
    }

    typealias DocumentIdentifier = String?

    private let source: UITextView
    private let preview: (String, [String: Any]?) async throws -> Any?
    private let onVisibility: (Bool) -> Void
    private(set) lazy var interaction = UIFindInteraction(sessionDelegate: self)
    private var usingSource = false
    private var generation = 0
    private var snapshotID: Int?
    private var searchTask: Task<Void, Never>?
    private var decorationTask: Task<Void, Never>?
    private var decorations: [[String: Int]] = []
    private var active = false
    private var currentRange: Range?
    private weak var currentSession: UIFindSession?
    private var sourceRanges: [NSRange: UITextSearchFoundTextStyle] = [:]
    private var aggregator: UITextSearchAggregator<DocumentIdentifier>?

    init(
        view: UIView, source: UITextView,
        preview: @escaping (String, [String: Any]?) async throws -> Any?,
        onVisibility: @escaping (Bool) -> Void
    ) {
        self.source = source
        self.preview = preview
        self.onVisibility = onVisibility
        super.init()
        view.addInteraction(interaction)
    }

    func present(source: Bool) {
        guard !active else { return }
        usingSource = source
        if source {
            self.source.textLayoutManager?.renderingAttributesValidator = { [weak self] _, fragment in
                self?.validateSourceHighlights(fragment)
            }
        }
        interaction.searchText = nil
        interaction.presentFindNavigator(showingReplace: false)
    }

    func dismiss() {
        active = false
        interaction.activeFindSession?.invalidateFoundResults()
        interaction.dismissFindNavigator()
        source.textLayoutManager?.renderingAttributesValidator = nil
        clearAllDecoratedFoundText()
        currentSession = nil
        aggregator = nil
        onVisibility(false)
    }

    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        return UITextSearchingFindSession(searchableObject: self)
    }

    func findInteraction(_ interaction: UIFindInteraction, didBegin session: UIFindSession) {
        currentSession = session
        active = true
        onVisibility(true)
    }

    func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
        guard currentSession === session else { return }
        active = false
        session.invalidateFoundResults()
        currentSession = nil
        source.textLayoutManager?.renderingAttributesValidator = nil
        clearAllDecoratedFoundText()
        active = false
        aggregator = nil
        onVisibility(false)
    }

    var selectedTextRange: UITextRange? { usingSource ? Range(source.selectedRange) : nil }
    var supportsTextReplacement: Bool { false }

    func compare(
        _ foundRange: UITextRange, toRange: UITextRange, document: DocumentIdentifier?
    ) -> ComparisonResult {
        guard let first = foundRange as? Range, let last = toRange as? Range else { return .orderedSame }
        return first.value.location < last.value.location
            ? .orderedAscending
            : first.value.location == last.value.location ? .orderedSame : .orderedDescending
    }

    func performTextSearch(
        queryString: String, options: UITextSearchOptions,
        resultAggregator aggregator: UITextSearchAggregator<DocumentIdentifier>
    ) {
        guard active else {
            aggregator.finishedSearching()
            return
        }
        self.aggregator = aggregator
        generation += 1
        let request = generation
        if usingSource {
            for range in Self.matches(in: source.text ?? "", query: queryString, options: options) {
                aggregator.foundRange(Range(range), searchString: queryString, document: nil)
            }
            aggregator.finishedSearching()
            return
        }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.preview("findCapture", nil) as? [String: Any]
                guard let id = snapshot?["id"] as? Int, let text = snapshot?["text"] as? String else { return }
                guard !Task.isCancelled, self.active, self.generation == request else {
                    _ = try? await self.preview("findClear", ["id": id])
                    return
                }
                self.snapshotID = id
                for range in Self.matches(in: text, query: queryString, options: options) {
                    aggregator.foundRange(Range(range), searchString: queryString, document: nil)
                }
                aggregator.finishedSearching()
            } catch {
                guard !Task.isCancelled, self.generation == request else { return }
                aggregator.finishedSearching()
            }
        }
    }

    static func matches(in text: String, query: String, options: UITextSearchOptions) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let string = text as NSString
        var starts = Set<Int>()
        var ends = Set<Int>()
        if options.wordMatchMethod != .contains {
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .localized]) {
                _, range, _, _ in
                let word = NSRange(range, in: text)
                starts.insert(word.location)
                ends.insert(NSMaxRange(word))
            }
        }
        var cursor = 0
        var result: [NSRange] = []
        while cursor < string.length {
            let range = string.range(
                of: query, options: options.stringCompareOptions.subtracting(.backwards),
                range: NSRange(location: cursor, length: string.length - cursor))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if options.wordMatchMethod == .contains
                || (starts.contains(range.location)
                    && (options.wordMatchMethod != .fullWord || ends.contains(NSMaxRange(range))))
            {
                result.append(range)
            }
            cursor = NSMaxRange(range)
        }
        return result
    }

    func decorate(
        foundTextRange range: UITextRange, document: DocumentIdentifier?,
        usingStyle style: UITextSearchFoundTextStyle
    ) {
        guard let range = range as? Range else { return }
        if style == .highlighted {
            currentRange = range
        } else if currentRange?.value == range.value {
            currentRange = nil
        }
        if usingSource {
            decorateSource(range.value, style: style)
            return
        }
        guard let id = snapshotID else { return }
        decorations.append(["start": range.value.location, "length": range.value.length, "style": style.rawValue])
        guard decorationTask == nil else { return }
        decorationTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.snapshotID == id else { return }
            let ranges = self.decorations
            self.decorations.removeAll()
            self.decorationTask = nil
            _ = try? await self.preview("findDecorate", ["id": id, "ranges": ranges])
        }
    }

    func clearAllDecoratedFoundText() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        decorationTask?.cancel()
        decorationTask = nil
        decorations.removeAll()
        currentRange = nil
        let previousSnapshot = snapshotID
        snapshotID = nil
        if usingSource {
            for range in sourceRanges.keys { decorateSource(range, style: .normal) }
            sourceRanges.removeAll()
        } else if let previousSnapshot {
            Task { _ = try? await preview("findClear", ["id": previousSnapshot]) }
        }
    }

    func scrollRangeToVisible(_ range: UITextRange, inDocument document: DocumentIdentifier?) {
        guard let range = range as? Range else { return }
        if usingSource {
            guard let start = source.position(from: source.beginningOfDocument, offset: range.value.location),
                let end = source.position(from: start, offset: range.value.length),
                let selection = source.textRange(from: start, to: end)
            else { return }
            let rect = source.firstRect(for: selection)
            let bottom = max(0, source.contentSize.height - source.bounds.height + source.adjustedContentInset.bottom)
            source.setContentOffset(
                CGPoint(x: source.contentOffset.x, y: min(bottom, max(0, rect.midY - source.bounds.height / 2))),
                animated: false)
            return
        }
        guard let id = snapshotID else { return }
        Task {
            _ = try? await preview(
                "findReveal", ["id": id, "start": range.value.location, "length": range.value.length])
        }
    }
    private func decorateSource(_ range: NSRange, style: UITextSearchFoundTextStyle) {
        if style == .normal { sourceRanges.removeValue(forKey: range) } else { sourceRanges[range] = style }
        renderSource(range, style: style)
    }

    private func renderSource(_ range: NSRange, style: UITextSearchFoundTextStyle) {
        guard NSMaxRange(range) <= (source.text as NSString?)?.length ?? 0,
            let layout = source.textLayoutManager, let content = layout.textContentManager,
            let start = content.location(content.documentRange.location, offsetBy: range.location),
            let end = content.location(start, offsetBy: range.length)
        else { return }
        guard let textRange = NSTextRange(location: start, end: end) else { return }
        if style == .normal {
            layout.removeRenderingAttribute(.backgroundColor, for: textRange)
            layout.removeRenderingAttribute(.foregroundColor, for: textRange)
        } else {
            layout.addRenderingAttribute(
                .backgroundColor, value: UIColor.systemYellow.withAlphaComponent(style == .highlighted ? 1 : 0.35),
                for: textRange)
            if style == .highlighted {
                layout.addRenderingAttribute(.foregroundColor, value: UIColor.black, for: textRange)
            } else {
                layout.removeRenderingAttribute(.foregroundColor, for: textRange)
            }
        }
    }

    private func validateSourceHighlights(_ fragment: NSTextLayoutFragment) {
        guard !sourceRanges.isEmpty, let content = source.textLayoutManager?.textContentManager else { return }
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let end = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.endLocation)
        guard start >= 0, end >= start else { return }
        let visible = NSRange(location: start, length: end - start)
        for (range, style) in sourceRanges {
            let intersection = NSIntersectionRange(range, visible)
            if intersection.length > 0 { renderSource(intersection, style: style) }
        }
    }

    func viewportChanged() {
        guard active, usingSource, let currentRange else { return }
        scrollRangeToVisible(currentRange, inDocument: nil)
    }

    func sourceChanged() {
        guard active, usingSource else { return }
        aggregator?.invalidate()
    }

}
