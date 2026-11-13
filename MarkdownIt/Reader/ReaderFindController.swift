import UIKit

/// Owns one transient find session. The bar, matching and result navigation are
/// shared; TextKit and CSS only project highlights into their respective views.
@MainActor
final class ReaderFindController {
    struct Options: Equatable {
        enum WordMatch: CaseIterable { case contains, startsWith, fullWord }
        var matchCase = false
        var ignoreDiacritics = true
        var wordMatchMethod = WordMatch.contains
        var comparison: String.CompareOptions {
            (matchCase ? [] : String.CompareOptions.caseInsensitive)
                .union(ignoreDiacritics ? .diacriticInsensitive : [])
        }
    }

    private enum HighlightStyle: Int { case none, found, current }
    let bar = ReaderFindBar()
    private let source: UITextView
    private let preview: (String, [String: Any]?) async throws -> Any?
    private let onVisibility: (Bool) -> Void
    private let onError: (Error) -> Void
    private(set) var active = false
    private(set) var query = ""
    private(set) var options = Options()
    private(set) var ranges: [NSRange] = []
    private(set) var currentIndex: Int?
    var resultCount: Int { ranges.count }
    private var usingSource = false
    private var generation = 0
    private var snapshotID: Int?
    private var searchTask: Task<Void, Never>?
    private var decorationTask: Task<Void, Never>?
    private var decorations: [[String: Int]] = []
    private var pendingReveal: NSRange?
    private var sourceRanges: [NSRange: HighlightStyle] = [:]

    init(
        source: UITextView, preview: @escaping (String, [String: Any]?) async throws -> Any?,
        onVisibility: @escaping (Bool) -> Void, onError: @escaping (Error) -> Void
    ) {
        self.source = source
        self.preview = preview
        self.onVisibility = onVisibility
        self.onError = onError
        bar.onQuery = { [weak self] in self?.search($0) }
        bar.onNext = { [weak self] in self?.move(forward: true) }
        bar.onPrevious = { [weak self] in self?.move(forward: false) }
        bar.onClose = { [weak self] in self?.dismiss() }
        bar.onOptions = { [weak self] options in
            guard let self else { return }
            self.options = options
            self.search(self.query)
        }
    }

    func present(source: Bool) {
        guard !active else {
            bar.focus()
            return
        }
        usingSource = source
        active = true
        if source {
            self.source.textLayoutManager?.renderingAttributesValidator = { [weak self] _, fragment in
                self?.validateSourceHighlights(fragment)
            }
        }
        query = ""
        bar.field.text = ""
        bar.setVisible(true)
        updateBar()
        bar.superview?.setNeedsLayout()
        bar.focus()
        onVisibility(true)
    }

    func dismiss() {
        guard active else { return }
        active = false
        bar.blur()
        bar.setVisible(false)
        clearHighlights()
        query = ""
        ranges.removeAll()
        currentIndex = nil
        source.textLayoutManager?.renderingAttributesValidator = nil
        onVisibility(false)
    }

    func search(_ query: String) {
        guard active else { return }
        let anchor = self.query == query ? currentIndex.map { ranges[$0].location } : nil
        clearHighlights()
        self.query = query
        ranges = []
        currentIndex = nil
        updateBar(searching: !query.isEmpty)
        guard !query.isEmpty else { return }
        let request = generation
        if usingSource {
            install(Self.matches(in: source.text ?? "", query: query, options: options), anchor: anchor)
        } else {
            searchTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let snapshot = try await self.preview("findCapture", nil) as? [String: Any]
                    guard let id = snapshot?["id"] as? Int, let text = snapshot?["text"] as? String else {
                        throw CocoaError(.coderReadCorrupt)
                    }
                    guard !Task.isCancelled, self.active, self.generation == request else {
                        _ = try? await self.preview("findClear", ["id": id])
                        return
                    }
                    self.snapshotID = id
                    self.install(Self.matches(in: text, query: query, options: self.options), anchor: anchor)
                } catch {
                    guard !Task.isCancelled, self.active, self.generation == request else { return }
                    self.updateBar()
                    self.onError(error)
                }
            }
        }
    }

    private func install(_ ranges: [NSRange], anchor: Int?) {
        self.ranges = ranges
        currentIndex =
            ranges.isEmpty
            ? nil
            : (anchor.flatMap { location in
                ranges.firstIndex { $0.location >= location }
            } ?? 0)
        for (index, range) in ranges.enumerated() {
            decorate(range, style: index == currentIndex ? .current : .found)
        }
        if let currentIndex { reveal(ranges[currentIndex]) }
        updateBar()
    }

    func move(forward: Bool) {
        guard active, !ranges.isEmpty, let currentIndex else { return }
        let next = (currentIndex + (forward ? 1 : ranges.count - 1)) % ranges.count
        decorate(ranges[currentIndex], style: .found)
        self.currentIndex = next
        decorate(ranges[next], style: .current)
        reveal(ranges[next])
        updateBar()
    }

    private func updateBar(searching: Bool = false) {
        bar.update(query: query, index: currentIndex, count: ranges.count, searching: searching, options: options)
    }

    static func matches(in text: String, query: String, options: Options = Options()) -> [NSRange] {
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
                of: query, options: options.comparison,
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

    private func decorate(_ range: NSRange, style: HighlightStyle) {
        if usingSource {
            decorateSource(range, style: style)
        } else {
            decorations.append(["start": range.location, "length": range.length, "style": style.rawValue])
            scheduleDecoration()
        }
    }

    private func scheduleDecoration() {
        guard decorationTask == nil, let id = snapshotID else { return }
        let request = generation
        decorationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == request { self.decorationTask = nil } }
            do {
                while !Task.isCancelled, self.active, self.generation == request {
                    let updates = self.decorations
                    self.decorations.removeAll()
                    if !updates.isEmpty {
                        _ = try await self.preview("findDecorate", ["id": id, "ranges": updates])
                    }
                    guard !Task.isCancelled, self.active, self.generation == request else { return }
                    if !self.decorations.isEmpty { continue }
                    if let range = self.pendingReveal {
                        self.pendingReveal = nil
                        _ = try await self.preview(
                            "findReveal", ["id": id, "start": range.location, "length": range.length])
                    }
                    if self.decorations.isEmpty && self.pendingReveal == nil { return }
                }
            } catch {
                guard !Task.isCancelled, self.active, self.generation == request else { return }
                self.onError(error)
            }
        }
    }

    private func clearHighlights() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        decorationTask?.cancel()
        decorationTask = nil
        decorations.removeAll()
        pendingReveal = nil
        let previousSnapshot = snapshotID
        snapshotID = nil
        for range in Array(sourceRanges.keys) { decorateSource(range, style: .none) }
        if let previousSnapshot {
            Task { _ = try? await preview("findClear", ["id": previousSnapshot]) }
        }
    }

    private func reveal(_ range: NSRange) {
        if usingSource {
            guard let start = source.position(from: source.beginningOfDocument, offset: range.location),
                let end = source.position(from: start, offset: range.length),
                let selection = source.textRange(from: start, to: end)
            else { return }
            let rect = source.firstRect(for: selection)
            let bottom = max(0, source.contentSize.height - source.bounds.height + source.adjustedContentInset.bottom)
            source.setContentOffset(
                CGPoint(x: source.contentOffset.x, y: min(bottom, max(0, rect.midY - source.bounds.height / 2))),
                animated: false)
        } else {
            pendingReveal = range
            scheduleDecoration()
        }
    }

    private func decorateSource(_ range: NSRange, style: HighlightStyle) {
        if style == .none { sourceRanges.removeValue(forKey: range) } else { sourceRanges[range] = style }
        renderSource(range, style: style)
    }

    private func renderSource(_ range: NSRange, style: HighlightStyle) {
        guard NSMaxRange(range) <= (source.text as NSString?)?.length ?? 0,
            let layout = source.textLayoutManager, let content = layout.textContentManager,
            let start = content.location(content.documentRange.location, offsetBy: range.location),
            let end = content.location(start, offsetBy: range.length)
        else { return }
        guard let textRange = NSTextRange(location: start, end: end) else { return }
        if style == .none {
            layout.removeRenderingAttribute(.backgroundColor, for: textRange)
            layout.removeRenderingAttribute(.foregroundColor, for: textRange)
        } else {
            layout.addRenderingAttribute(
                .backgroundColor, value: UIColor.systemYellow.withAlphaComponent(style == .current ? 1 : 0.35),
                for: textRange)
            if style == .current {
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
        guard active, usingSource, let currentIndex else { return }
        reveal(ranges[currentIndex])
    }

    func sourceChanged() {
        guard active, usingSource else { return }
        search(query)
    }
}
