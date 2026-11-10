import Foundation

struct SourceSelection: Codable, Equatable, Sendable {
    var range: NSRange
    var scrollY: CGFloat = 0
}

/// UIKit can offer this manager in system menus without registering a second
/// set of text mutations. The document model is the sole registration owner.
@MainActor
final class SourceUndoManager: UndoManager {
    private var modelOperation = false
    weak var registrationTarget: AnyObject?

    func performModelOperation(_ action: () -> Void) {
        let previous = modelOperation
        modelOperation = true
        defer { modelOperation = previous }
        action()
    }

    override func beginUndoGrouping() { if modelOperation { super.beginUndoGrouping() } }
    override func endUndoGrouping() { if modelOperation { super.endUndoGrouping() } }
    override func removeAllActions() {}
    func reset() { super.removeAllActions() }
    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
        if target as AnyObject === registrationTarget {
            super.registerUndo(withTarget: target, selector: selector, object: anObject)
        }
    }
    override func __registerUndoWithTarget(_ target: Any, handler undoHandler: @escaping @MainActor (Any) -> Void) {
        if target as AnyObject === registrationTarget { super.__registerUndoWithTarget(target, handler: undoHandler) }
    }
    override func undo() { performModelOperation { super.undo() } }
    override func redo() { performModelOperation { super.redo() } }
}

/// Owns the working text and edit transactions. Text views and Web snapshots are projections.
@MainActor
final class SourceHistory {
    enum InputKind: String, Codable, Sendable { case typing, backwardDelete, forwardDelete, composition, transaction }

    struct Edit: Sendable {
        enum Action: Sendable { case record, undo, redo }
        let id: String
        struct Delta: Codable, Equatable, Sendable {
            let start: Int
            let removed: Int
            let inserted: Int
        }
        let changes: [Delta]
        let action: Action
        init(id: String, start: Int, removed: Int, inserted: Int, action: Action) {
            self.init(id: id, changes: [Delta(start: start, removed: removed, inserted: inserted)], action: action)
        }
        init(id: String, changes: [Delta], action: Action) {
            self.id = id
            self.changes = changes
            self.action = action
        }
    }

    struct Snapshot: Codable, Equatable, Sendable {
        let text: String
        let revision: Int
        fileprivate let undo: [Transaction]
        fileprivate let redo: [Transaction]

        func edits(forward: Bool) -> [Edit] {
            (forward ? redo : undo).reversed().map { $0.edit(forward: forward) }
        }

        var latestEdit: Edit? { undo.last?.edit(forward: true) }
    }

    fileprivate struct Transaction: Codable, Equatable, Sendable {
        let id: String
        let start: Int
        let before: String
        let after: String
        let kind: InputKind
        let beforeSelection: SourceSelection
        let afterSelection: SourceSelection
        let changes: [Edit.Delta]?

        func edit(forward: Bool) -> Edit {
            let deltas: [Edit.Delta]
            if let changes {
                deltas =
                    forward
                    ? changes
                    : changes.reversed().map {
                        .init(start: $0.start, removed: $0.inserted, inserted: $0.removed)
                    }
            } else {
                deltas = [
                    .init(
                        start: start, removed: (forward ? before : after).utf16.count,
                        inserted: (forward ? after : before).utf16.count)
                ]
            }
            return Edit(id: id, changes: deltas, action: forward ? .redo : .undo)
        }
    }

    private final class Entry {
        let id: String
        var start: Int
        var before: String
        var after: String
        let kind: InputKind
        let beforeSelection: SourceSelection
        var afterSelection: SourceSelection
        let changes: [Edit.Delta]?

        init(
            id: String, start: Int, before: String, after: String, kind: InputKind,
            beforeSelection: SourceSelection, afterSelection: SourceSelection, changes: [Edit.Delta]? = nil
        ) {
            self.id = id
            self.start = start
            self.before = before
            self.after = after
            self.kind = kind
            self.beforeSelection = beforeSelection
            self.afterSelection = afterSelection
            self.changes = changes
        }

        convenience init(_ value: Transaction) {
            self.init(
                id: value.id, start: value.start, before: value.before, after: value.after, kind: value.kind,
                beforeSelection: value.beforeSelection, afterSelection: value.afterSelection, changes: value.changes)
        }

        var snapshot: Transaction {
            Transaction(
                id: id, start: start, before: before, after: after, kind: kind,
                beforeSelection: beforeSelection, afterSelection: afterSelection, changes: changes)
        }
    }

    private final class UndoTarget {
        weak var history: SourceHistory?
    }

    let undoManager = SourceUndoManager()
    private(set) var text = ""
    private(set) var revision = 0
    private var undo: [Entry] = []
    private var redo: [Entry] = []
    private var group: Entry?
    private var restoring = false
    private let undoTarget = UndoTarget()
    var onChange: ((SourceSelection, String?, String?) -> Void)?
    var onEdit: ((Edit) -> Void)?

    init() {
        undoTarget.history = self
        undoManager.registrationTarget = undoTarget
        undoManager.groupsByEvent = false
    }

    var canUndo: Bool { !undo.isEmpty }
    var canRedo: Bool { !redo.isEmpty }
    var transactionIDs: Set<String> { Set(undo.map(\.id) + redo.map(\.id)) }

    func reset(_ value: String) {
        undoManager.reset()
        undo.removeAll()
        redo.removeAll()
        group = nil
        text = value
        revision += 1
    }

    func breakGroup() { group = nil }

    func snapshot() -> Snapshot {
        Snapshot(text: text, revision: revision, undo: undo.map(\.snapshot), redo: redo.map(\.snapshot))
    }

    /// Preserve unconfirmed native input as a value without ending the live IME session.
    func snapshot(including value: String, before: SourceSelection, after: SourceSelection) -> Snapshot {
        let committed = snapshot()
        guard value != text else { return committed }
        let patch = Self.difference(text, value, maximumPrefix: min(before.range.location, after.range.location))
        let pending = Transaction(
            id: UUID().uuidString.lowercased(), start: patch.start, before: patch.before, after: patch.after,
            kind: .composition, beforeSelection: before, afterSelection: after, changes: nil)
        return Snapshot(text: value, revision: revision + 1, undo: committed.undo + [pending], redo: [])
    }

    func restore(_ snapshot: Snapshot) throws {
        guard snapshot.revision >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        func validate(_ transactions: [Transaction], forward: Bool) throws {
            let value = NSMutableString(string: snapshot.text)
            for transaction in transactions.reversed() {
                let expected = forward ? transaction.before : transaction.after
                let replacement = forward ? transaction.after : transaction.before
                let beforeSelection = forward ? transaction.beforeSelection : transaction.afterSelection
                let afterSelection = forward ? transaction.afterSelection : transaction.beforeSelection
                let start = transaction.start
                guard start >= 0, start <= value.length, expected.utf16.count <= value.length - start,
                    Self.valid(beforeSelection, length: value.length),
                    value.substring(with: NSRange(location: start, length: expected.utf16.count)) == expected
                else { throw CocoaError(.fileReadCorruptFile) }
                if let changes = transaction.changes {
                    let beforeLength =
                        forward ? value.length : value.length - expected.utf16.count + replacement.utf16.count
                    let afterLength =
                        forward ? value.length - expected.utf16.count + replacement.utf16.count : value.length
                    var length = beforeLength
                    var previousStart = beforeLength
                    guard !changes.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    for change in changes {
                        // Tool deltas describe the requested ranges in the whole
                        // buffer; the stored text patch trims unchanged edges.
                        guard change.start >= 0, change.removed >= 0, change.inserted >= 0,
                            change.start <= previousStart, change.removed <= previousStart - change.start,
                            change.start <= length, change.removed <= length - change.start,
                            change.inserted <= Int.max - (length - change.removed)
                        else { throw CocoaError(.fileReadCorruptFile) }
                        previousStart = change.start
                        length = length - change.removed + change.inserted
                    }
                    guard length == afterLength else { throw CocoaError(.fileReadCorruptFile) }
                }
                value.replaceCharacters(in: NSRange(location: start, length: expected.utf16.count), with: replacement)
                guard Self.valid(afterSelection, length: value.length) else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        try validate(snapshot.undo, forward: false)
        try validate(snapshot.redo, forward: true)
        reset(snapshot.text)
        // UndoManager owns executable actions. Rebuild both stacks from value records,
        // suppressing text changes and callbacks while replaying the stack topology.
        restoring = true
        defer { restoring = false }
        for transaction in snapshot.undo + snapshot.redo.reversed() {
            let entry = Entry(transaction)
            undo.append(entry)
            register(entry, forward: false)
        }
        for _ in snapshot.redo { undoManager.undo() }
        revision = snapshot.revision
        group = nil
    }

    private static func valid(_ selection: SourceSelection, length: Int) -> Bool {
        selection.range.location >= 0 && selection.range.location <= length && selection.range.length >= 0
            && selection.range.length <= length - selection.range.location && selection.scrollY.isFinite
    }

    func record(
        _ value: String, before: SourceSelection, after selection: SourceSelection? = nil,
        kind requestedKind: InputKind = .transaction, id: String = UUID().uuidString.lowercased(),
        changes: [Edit.Delta]? = nil
    ) {
        guard value != text else { return }
        let patch = Self.difference(
            text, value, maximumPrefix: selection.map { min(before.range.location, $0.range.location) })
        let kind: InputKind
        if requestedKind == .typing && patch.after.isEmpty {
            kind =
                before.range.length > 0
                ? .transaction : patch.start < before.range.location ? .backwardDelete : .forwardDelete
        } else {
            kind = requestedKind
        }
        let delta = patch.after.utf16.count - patch.before.utf16.count
        let end = patch.start + patch.before.utf16.count
        func moved(_ offset: Int) -> Int {
            if offset <= patch.start { return offset }
            if offset >= end { return offset + delta }
            return patch.start + min(offset - patch.start, patch.after.utf16.count)
        }
        let start = moved(before.range.location)
        let after =
            selection
            ?? SourceSelection(
                range: NSRange(location: start, length: moved(NSMaxRange(before.range)) - start),
                scrollY: before.scrollY)
        var entry: Entry?
        var merged = false
        if let previous = group, undo.last === previous, previous.kind == kind {
            let previousAfterCount = previous.after.utf16.count
            if kind == .typing, patch.before.isEmpty, previous.before.isEmpty,
                patch.start == previous.start + previousAfterCount
            {
                previous.after += patch.after
                merged = true
            } else if kind == .backwardDelete, patch.after.isEmpty, previous.after.isEmpty,
                patch.start + patch.before.utf16.count == previous.start
            {
                previous.start = patch.start
                previous.before = patch.before + previous.before
                merged = true
            } else if kind == .forwardDelete, patch.after.isEmpty, previous.after.isEmpty,
                patch.start == previous.start
            {
                previous.before += patch.before
                merged = true
            }
            if merged { entry = previous }
        }
        if !merged {
            let transaction = Entry(
                id: id, start: patch.start, before: patch.before, after: patch.after, kind: kind,
                beforeSelection: before, afterSelection: after, changes: changes)
            entry = transaction
            undo.append(transaction)
            register(transaction, forward: false)
        }
        guard let entry else { return }
        entry.afterSelection = after
        redo.removeAll()
        text = value
        revision += 1
        group = kind == .transaction || kind == .composition ? nil : entry
        if kind == .typing, let last = patch.after.unicodeScalars.last,
            CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?;:。！？；，")).contains(last)
        {
            group = nil
        }
        onEdit?(
            Edit(
                id: entry.id,
                changes: changes ?? [
                    .init(
                        start: patch.start, removed: patch.before.utf16.count,
                        inserted: patch.after.utf16.count)
                ], action: .record))
        onChange?(after, entry.id, "applied")
    }

    @discardableResult
    func move(forward: Bool, id: String? = nil) -> Bool {
        guard forward ? canRedo : canUndo else { return false }
        if let id, (forward ? redo.last : undo.last)?.id != id { return false }
        if forward { undoManager.redo() } else { undoManager.undo() }
        return true
    }

    private func register(_ entry: Entry, forward: Bool) {
        undoManager.performModelOperation {
            if !undoManager.isUndoing && !undoManager.isRedoing { undoManager.beginUndoGrouping() }
            undoManager.registerUndo(withTarget: undoTarget) { target in
                target.history?.replay(entry, forward: forward)
            }
            if !undoManager.isUndoing && !undoManager.isRedoing { undoManager.endUndoGrouping() }
        }
    }

    private func replay(_ entry: Entry, forward: Bool) {
        let expected = forward ? entry.before : entry.after
        let replacement = forward ? entry.after : entry.before
        let range = NSRange(location: entry.start, length: expected.utf16.count)
        if !restoring {
            let current = text as NSString
            precondition(NSMaxRange(range) <= current.length && current.substring(with: range) == expected)
            text = current.replacingCharacters(in: range, with: replacement)
        }
        if forward {
            redo.removeLast()
            undo.append(entry)
        } else {
            undo.removeLast()
            redo.append(entry)
        }
        register(entry, forward: !forward)
        group = nil
        guard !restoring else { return }
        revision += 1
        onEdit?(entry.snapshot.edit(forward: forward))
        onChange?(forward ? entry.afterSelection : entry.beforeSelection, entry.id, forward ? "applied" : "undone")
    }

    private static func difference(
        _ before: String, _ after: String, maximumPrefix: Int?
    ) -> (start: Int, before: String, after: String) {
        let old = Array(before.utf16)
        let new = Array(after.utf16)
        // Repeated characters admit several equal text diffs. Native selection
        // boundaries identify the actual edit, so adjacent deletions still merge.
        let prefixLimit = min(old.count, new.count, maximumPrefix ?? Int.max)
        var prefix = 0
        while prefix < prefixLimit && old[prefix] == new[prefix] { prefix += 1 }
        if prefix > 0, prefix < old.count, (0xDC00...0xDFFF).contains(old[prefix]) { prefix -= 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix
            && old[old.count - suffix - 1] == new[new.count - suffix - 1]
        {
            suffix += 1
        }
        if suffix > 0, (0xDC00...0xDFFF).contains(old[old.count - suffix]) { suffix -= 1 }
        return (
            prefix,
            (before as NSString).substring(with: NSRange(location: prefix, length: old.count - prefix - suffix)),
            (after as NSString).substring(with: NSRange(location: prefix, length: new.count - prefix - suffix))
        )
    }
}
