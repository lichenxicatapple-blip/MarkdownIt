import Foundation

/// Half-open UTF-16 positions in the native document buffer, shared with DOM Range.
struct AnnotationRange: Codable, Equatable, Sendable {
    var start: Int
    var end: Int

    var isValid: Bool { start >= 0 && end > start }

    func replacing(at start: Int, removed: Int, inserted: Int) -> Self? {
        guard start >= 0, removed >= 0, inserted >= 0, removed <= Int.max - start else { return nil }
        let oldEnd = start + removed
        let delta = inserted - removed
        if end <= start { return self }
        if self.start >= oldEnd {
            let first = self.start.addingReportingOverflow(delta)
            let last = end.addingReportingOverflow(delta)
            guard !first.overflow, !last.overflow else { return nil }
            return Self(start: first.partialValue, end: last.partialValue)
        }
        guard inserted <= Int.max - start, delta <= 0 || end <= Int.max - delta else { return nil }
        let first = self.start < start ? self.start : start + inserted
        let last = end > oldEnd ? end + delta : start
        return last > first ? Self(start: first, end: last) : nil
    }

    static func normalized(_ ranges: [Self]) -> [Self] {
        var result: [Self] = []
        for range in ranges.filter(\.isValid).sorted(by: { $0.start < $1.start }) {
            if let previous = result.last, range.start <= previous.end {
                result[result.count - 1].end = max(previous.end, range.end)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

struct ReadingAnnotation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var ranges: [AnnotationRange]
    var underlined: Bool
    var note: String

    var isVisible: Bool { !ranges.isEmpty && (underlined || !note.isEmpty) }
}

/// User actions change content; source history changes positions only. Empty ranges
/// retain source-deletion tombstones until that document's undo history is retired.
struct ReadingAnnotations: Codable, Equatable, Sendable {
    struct Effect: Codable, Equatable, Sendable {
        var before: [UUID: [AnnotationRange]] = [:]
        var after: [UUID: [AnnotationRange]] = [:]
    }

    var sourceRevision: String?
    private(set) var records: [ReadingAnnotation] = []
    private(set) var effects: [String: Effect] = [:]
    var visible: [ReadingAnnotation] { records.filter(\.isVisible) }

    /// Merge plain underlines only. Renderer-supplied joins bridge invisible
    /// Markdown delimiters; native overlap checks also work without rendering.
    mutating func addUnderline(
        ranges: [AnnotationRange], joining: Set<UUID> = [], history: SourceHistory.Snapshot
    ) throws {
        let ranges = AnnotationRange.normalized(ranges)
        guard !ranges.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
        if let note = records.first(where: { !$0.note.isEmpty && $0.ranges == ranges }) {
            try set(ranges: ranges, underlined: true, id: note.id)
            return
        }
        var combined = ranges
        var ids = Set<UUID>()
        var changed = true
        while changed {
            changed = false
            for record in visible where record.note.isEmpty && record.underlined && !ids.contains(record.id) {
                let touches = record.ranges.contains { old in
                    combined.contains { $0.start <= old.end && old.start <= $0.end }
                }
                if touches || joining.contains(record.id) {
                    ids.insert(record.id)
                    combined = AnnotationRange.normalized(combined + record.ranges)
                    changed = true
                }
            }
        }
        guard let retained = records.first(where: { ids.contains($0.id) }) else {
            try set(ranges: ranges, underlined: true)
            return
        }
        if ids.count == 1 && retained.ranges == combined { return }

        // Combine historical ranges through the same source transforms. A new
        // stroke must preserve positions restored by an earlier source undo.
        var origin = self
        let stroke = UUID()
        origin.records.append(ReadingAnnotation(id: stroke, ranges: ranges, underlined: true, note: ""))
        let members = ids.union([stroke])
        func union(_ value: Self) -> [AnnotationRange] {
            AnnotationRange.normalized(value.records.filter { members.contains($0.id) }.flatMap(\.ranges))
        }
        var historyRanges: [String: (before: [AnnotationRange], after: [AnnotationRange])] = [:]
        for forward in [false, true] {
            var cursor = origin
            for edit in history.edits(forward: forward) {
                let current = union(cursor)
                cursor.apply(edit)
                let next = union(cursor)
                historyRanges[edit.id] = forward ? (current, next) : (next, current)
            }
        }
        for id in ids where id != retained.id { remove(id) }
        let index = records.firstIndex { $0.id == retained.id }!
        records[index].ranges = combined
        for (id, ranges) in historyRanges {
            var effect = effects[id] ?? Effect()
            effect.before[retained.id] = ranges.before
            effect.after[retained.id] = ranges.after
            effects[id] = effect
        }
    }

    mutating func set(ranges: [AnnotationRange], underlined: Bool? = nil, note: String? = nil, id: UUID? = nil) throws {
        let ranges = AnnotationRange.normalized(ranges)
        guard !ranges.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
        let index =
            id.flatMap { id in records.firstIndex { $0.id == id } }
            ?? records.firstIndex { $0.ranges == ranges }
        if let index {
            if let underlined { records[index].underlined = underlined }
            if let note { records[index].note = note }
            if !records[index].underlined && records[index].note.isEmpty { remove(records[index].id) }
        } else {
            let record = ReadingAnnotation(
                id: UUID(), ranges: ranges, underlined: underlined ?? false, note: note ?? "")
            if record.isVisible { records.append(record) }
        }
    }

    mutating func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
        for key in effects.keys {
            effects[key]?.before.removeValue(forKey: id)
            effects[key]?.after.removeValue(forKey: id)
        }
    }

    mutating func apply(_ edit: SourceHistory.Edit) {
        var effect = effects[edit.id] ?? Effect()
        for index in records.indices {
            let id = records[index].id
            let current = records[index].ranges
            let transformed = edit.changes.reduce(current) { ranges, change in
                AnnotationRange.normalized(
                    ranges.compactMap {
                        $0.replacing(at: change.start, removed: change.removed, inserted: change.inserted)
                    })
            }
            switch edit.action {
            case .record:
                if effect.before[id] == nil { effect.before[id] = current }
                effect.after[id] = transformed
                records[index].ranges = transformed
            case .undo:
                if effect.after[id] == nil { effect.after[id] = current }
                if effect.before[id] == nil { effect.before[id] = transformed }
                records[index].ranges = effect.before[id] ?? transformed
            case .redo:
                if effect.before[id] == nil { effect.before[id] = current }
                if effect.after[id] == nil { effect.after[id] = transformed }
                records[index].ranges = effect.after[id] ?? transformed
            }
        }
        effects[edit.id] = effect
    }

    mutating func restoreHistory(from snapshot: Self) {
        let ids = Set(records.map(\.id))
        effects = snapshot.effects.mapValues { effect in
            Effect(
                before: effect.before.filter { ids.contains($0.key) },
                after: effect.after.filter { ids.contains($0.key) })
        }
    }

    mutating func retainHistory(_ ids: Set<String>) {
        effects = effects.filter { ids.contains($0.key) }
        let referenced = Set(effects.values.flatMap { Array($0.before.keys) + Array($0.after.keys) })
        records.removeAll { !$0.isVisible && !referenced.contains($0.id) }
    }

    mutating func retireHistory() { retainHistory([]) }

    func validate() throws {
        guard Set(records.map(\.id)).count == records.count,
            records.allSatisfy({ $0.ranges == AnnotationRange.normalized($0.ranges) }),
            effects.values.allSatisfy({ effect in
                [effect.before, effect.after].allSatisfy { value in
                    value.allSatisfy { id, ranges in
                        records.contains { $0.id == id } && ranges == AnnotationRange.normalized(ranges)
                    }
                }
            })
        else { throw CocoaError(.fileReadCorruptFile) }
    }
}
