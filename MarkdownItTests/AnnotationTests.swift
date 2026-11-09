import XCTest

@testable import MarkdownIt

final class AnnotationTests: XCTestCase {
    @MainActor
    func testPlainUnderlinesMergeTransitivelyAndNotesStayIndependent() throws {
        let history = SourceHistory()
        history.reset("abcdefghijklmnopqrst")
        var notes = ReadingAnnotations()
        for range in [AnnotationRange(start: 0, end: 3), .init(start: 6, end: 9), .init(start: 3, end: 6)] {
            try notes.addUnderline(ranges: [range], history: history.snapshot())
        }
        XCTAssertEqual(notes.visible.count, 1)
        XCTAssertEqual(notes.visible.first?.ranges, [.init(start: 0, end: 9)])
        let id = notes.visible.first?.id
        try notes.addUnderline(ranges: [.init(start: 2, end: 7)], history: history.snapshot())
        XCTAssertEqual(notes.visible.first?.id, id)
        try notes.set(ranges: [.init(start: 10, end: 13)], underlined: true, note: "Independent")
        try notes.addUnderline(ranges: [.init(start: 9, end: 16)], history: history.snapshot())
        XCTAssertEqual(notes.visible.count, 2)
        XCTAssertEqual(notes.visible.first { !$0.note.isEmpty }?.ranges, [.init(start: 10, end: 13)])
        XCTAssertEqual(notes.visible.first { $0.note.isEmpty }?.ranges, [.init(start: 0, end: 16)])
        try notes.addUnderline(ranges: [.init(start: 17, end: 20)], history: history.snapshot())
        XCTAssertEqual(notes.visible.count, 3, "Unmarked text keeps separate underlines apart")
        try notes.validate()
    }

    @MainActor
    func testMergedUnderlineKeepsBothUndoBranchesAndExplicitRemoval() throws {
        let history = SourceHistory()
        history.reset("abcdefghij")
        var notes = ReadingAnnotations()
        try notes.addUnderline(ranges: [.init(start: 0, end: 4)], history: history.snapshot())
        history.onEdit = { notes.apply($0) }
        history.record("cdefghij", before: .init(range: NSRange(location: 0, length: 2)))
        try notes.addUnderline(ranges: [.init(start: 1, end: 5)], history: history.snapshot())
        XCTAssertEqual(notes.visible.first?.ranges, [.init(start: 0, end: 5)])
        XCTAssertTrue(history.move(forward: false))
        XCTAssertEqual(notes.visible.first?.ranges, [.init(start: 0, end: 7)])
        try notes.addUnderline(ranges: [.init(start: 6, end: 9)], history: history.snapshot())
        XCTAssertTrue(history.move(forward: true))
        XCTAssertEqual(notes.visible.first?.ranges, [.init(start: 0, end: 7)])
        XCTAssertTrue(history.move(forward: false))
        XCTAssertEqual(notes.visible.first?.ranges, [.init(start: 0, end: 9)])
        let record = try XCTUnwrap(notes.visible.first)
        try notes.set(ranges: record.ranges, underlined: false, id: record.id)
        XCTAssertTrue(history.move(forward: true))
        XCTAssertTrue(notes.visible.isEmpty)
        try notes.validate()
    }

    func testIndependentStatesAndExplicitRemovalNeverResurrects() throws {
        var notes = ReadingAnnotations()
        let range = AnnotationRange(start: 4, end: 10)
        try notes.set(ranges: [range], underlined: true)
        let id = try XCTUnwrap(notes.visible.first?.id)
        try notes.set(ranges: [range], note: "A thought", id: id)
        notes.apply(.init(id: "edit", start: 0, removed: 0, inserted: 3, action: .record))
        try notes.set(ranges: [.init(start: 7, end: 13)], underlined: false, id: id)
        notes.apply(.init(id: "edit", start: 0, removed: 3, inserted: 0, action: .undo))
        XCTAssertEqual(notes.visible.first?.note, "A thought")
        XCTAssertEqual(notes.visible.first?.underlined, false)
        try notes.set(ranges: [range], note: "", id: id)
        notes.apply(.init(id: "edit", start: 0, removed: 0, inserted: 3, action: .redo))
        XCTAssertTrue(notes.records.isEmpty)
    }

    func testPartialDeletionFullDeletionUndoAndLaterNoteEdits() throws {
        var notes = ReadingAnnotations()
        try notes.set(ranges: [.init(start: 3, end: 9)], underlined: true, note: "Original")
        let id = try XCTUnwrap(notes.visible.first?.id)
        notes.apply(.init(id: "partial", start: 5, removed: 2, inserted: 0, action: .record))
        XCTAssertEqual(notes.visible.first?.ranges, [.init(start: 3, end: 7)])
        try notes.set(ranges: [.init(start: 3, end: 7)], note: "Revised", id: id)
        notes.apply(.init(id: "delete", start: 3, removed: 4, inserted: 0, action: .record))
        XCTAssertTrue(notes.visible.isEmpty)
        notes.apply(.init(id: "delete", start: 3, removed: 0, inserted: 4, action: .undo))
        notes.apply(.init(id: "partial", start: 5, removed: 0, inserted: 2, action: .undo))
        XCTAssertEqual(notes.visible.first?.ranges, [.init(start: 3, end: 9)])
        XCTAssertEqual(notes.visible.first?.note, "Revised")
        try notes.validate()
    }

    @MainActor
    func testGroupedTypingAndSharedHistoryKeepExactRanges() throws {
        let history = SourceHistory()
        var notes = ReadingAnnotations()
        history.reset("hello 世界")
        try notes.set(ranges: [.init(start: 6, end: 8)], note: "Chinese")
        history.onEdit = { notes.apply($0) }
        history.record(
            "ahello 世界", before: .init(range: NSRange(location: 0, length: 0)),
            after: .init(range: NSRange(location: 1, length: 0)), kind: .typing)
        history.record(
            "abhello 世界", before: .init(range: NSRange(location: 1, length: 0)),
            after: .init(range: NSRange(location: 2, length: 0)), kind: .typing)
        XCTAssertEqual(notes.visible.first?.ranges, [.init(start: 8, end: 10)])
        XCTAssertTrue(history.move(forward: false))
        XCTAssertEqual(notes.visible.first?.ranges, [.init(start: 6, end: 8)])
        XCTAssertTrue(history.move(forward: true))
        XCTAssertEqual(notes.visible.first?.ranges, [.init(start: 8, end: 10)])
    }

    func testAnnotationsCreatedAfterAnEditFollowItsUndoAndRedo() throws {
        var notes = ReadingAnnotations()
        notes.apply(.init(id: "insert", start: 3, removed: 0, inserted: 4, action: .record))
        try notes.set(ranges: [.init(start: 3, end: 7)], note: "New text")
        notes.apply(.init(id: "insert", start: 3, removed: 4, inserted: 0, action: .undo))
        XCTAssertTrue(notes.visible.isEmpty)
        notes.apply(.init(id: "insert", start: 3, removed: 0, inserted: 4, action: .redo))
        XCTAssertEqual(notes.visible.first?.note, "New text")
        XCTAssertEqual(notes.visible.first?.ranges, [.init(start: 3, end: 7)])
    }

    func testStoreSeparatesPathsAndRejectsStaleOwners() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadingAnnotationStore(directory: root)
        let first = UUID()
        let second = UUID()
        _ = try await store.load(path: "/one/reading.md", owner: first)
        var notes = ReadingAnnotations()
        try notes.set(ranges: [.init(start: 1, end: 4)], note: "Saved")
        try await store.save(notes, path: "/one/reading.md", owner: first, revision: 1)
        let restored = try await store.load(path: "/one/reading.md", owner: second)
        XCTAssertEqual(restored, notes)
        try await store.save(ReadingAnnotations(), path: "/one/reading.md", owner: first, revision: 2)
        let final = try await store.load(path: "/one/reading.md", owner: UUID())
        XCTAssertEqual(final, notes)
        let other = try await store.load(path: "/two/reading.md", owner: UUID())
        XCTAssertTrue(other.records.isEmpty)
    }
    @MainActor
    func testAtomicDistantReplacementsPreserveTheMiddleAndUndoTogether() throws {
        let history = SourceHistory()
        var annotations = ReadingAnnotations()
        history.reset("first middle last")
        try annotations.set(ranges: [.init(start: 6, end: 12)], note: "Keep the middle")
        history.onEdit = { annotations.apply($0) }
        history.record(
            "FIRST++ middle X", before: .init(range: NSRange(location: 0, length: 0)),
            changes: [.init(start: 13, removed: 4, inserted: 1), .init(start: 0, removed: 5, inserted: 7)])
        XCTAssertEqual(annotations.visible.first?.ranges, [.init(start: 8, end: 14)])
        XCTAssertTrue(history.move(forward: false))
        XCTAssertEqual(history.text, "first middle last")
        XCTAssertEqual(annotations.visible.first?.ranges, [.init(start: 6, end: 12)])
        XCTAssertTrue(history.move(forward: true))
        XCTAssertEqual(annotations.visible.first?.ranges, [.init(start: 8, end: 14)])
    }

    @MainActor
    func testPencilOnlyClaimsUnderlineDirectionOutsideOverflowingContent() {
        let line = ReaderPencilInteraction.Region(
            x: 20, y: 30, width: 200, height: 12, fontSize: 16, lineHeight: 30, textY: 22, overflow: false)
        let table = ReaderPencilInteraction.Region(
            x: 20, y: 50, width: 200, height: 12, fontSize: 16, lineHeight: 30, textY: 42, overflow: true)
        XCTAssertEqual(ReaderPencilInteraction.intent(translation: CGPoint(x: 3, y: 9), region: line), .waiting)
        XCTAssertEqual(ReaderPencilInteraction.intent(translation: CGPoint(x: 13, y: 9), region: line), .underline)
        XCTAssertEqual(ReaderPencilInteraction.intent(translation: CGPoint(x: -13, y: -9), region: line), .underline)
        XCTAssertEqual(ReaderPencilInteraction.intent(translation: CGPoint(x: 2, y: 18), region: line), .scroll)
        XCTAssertEqual(ReaderPencilInteraction.intent(translation: CGPoint(x: 15, y: 2), region: table), .scroll)
        XCTAssertEqual(ReaderPencilInteraction.intent(translation: CGPoint(x: 15, y: 2), region: nil), .scroll)
    }

    @MainActor
    func testPencilStartingRegionsUseTheClosestLineWhenWhitespaceOverlaps() throws {
        let first = ReaderPencilInteraction.Region(
            x: 20, y: 30, width: 200, height: 24, fontSize: 16, lineHeight: 30, textY: 22, overflow: false)
        let second = ReaderPencilInteraction.Region(
            x: 20, y: 48, width: 200, height: 24, fontSize: 16, lineHeight: 30, textY: 40, overflow: false)
        let regions = [first, second]
        XCTAssertEqual(ReaderPencilInteraction.region(at: CGPoint(x: 30, y: 46), in: regions)?.textY, first.textY)
        XCTAssertEqual(ReaderPencilInteraction.region(at: CGPoint(x: 30, y: 53), in: regions)?.textY, second.textY)
        XCTAssertNil(ReaderPencilInteraction.region(at: CGPoint(x: 10, y: 46), in: regions))
        XCTAssertNil(ReaderPencilInteraction.region(at: CGPoint(x: 30, y: 80), in: regions))
    }

    @MainActor
    func testRestoredHistoryPreservesExactAnnotationEffectsAndNewerNoteText() throws {
        let history = SourceHistory()
        var notes = ReadingAnnotations()
        history.reset("hello world")
        try notes.set(ranges: [.init(start: 6, end: 11)], note: "First")
        history.onEdit = { notes.apply($0) }
        history.record("prefix hello world", before: .init(range: NSRange(location: 0, length: 0)))
        let checkpoint = notes
        try notes.set(ranges: [.init(start: 13, end: 18)], note: "Updated after checkpoint")
        notes.restoreHistory(from: checkpoint)
        let restored = SourceHistory()
        try restored.restore(history.snapshot())
        restored.onEdit = { notes.apply($0) }
        XCTAssertTrue(restored.move(forward: false))
        XCTAssertEqual(notes.visible.first?.ranges, [.init(start: 6, end: 11)])
        XCTAssertEqual(notes.visible.first?.note, "Updated after checkpoint")
    }

    @MainActor
    func testLongNoteUsesNativeScrollingAndBalancedTextInsets() {
        let text = String(repeating: "A long thought deserves space. 读书时留下一点自己的想法。\n\n", count: 30)
        let card = AnnotationCardView(note: text, underlined: false, existing: true)
        card.frame = CGRect(origin: .zero, size: card.fittingSize(width: 360, maximumHeight: 420))
        card.layoutIfNeeded()
        let input = card.textView
        XCTAssertGreaterThan(input.contentSize.height, input.bounds.height)
        XCTAssertEqual(
            input.frame.minX + input.textContainerInset.left,
            card.bounds.width - input.frame.maxX + input.textContainerInset.right)
        XCTAssertEqual(input.textContainerInset.right, ReaderDesign.annotationScrollbarGap)
        let frame = card.frame
        input.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
        XCTAssertEqual(card.frame, frame)
        XCTAssertEqual(input.text, text)
    }

}
