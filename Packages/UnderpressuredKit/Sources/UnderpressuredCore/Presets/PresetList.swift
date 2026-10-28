import Foundation

/// Ordered Presets. Always contains at least one Preset and exactly one active Preset.
public struct PresetList: Sendable, Hashable {
    public private(set) var presets: [Preset]
    public private(set) var activeID: UUID

    /// The most Presets the list holds; the bar wraps them onto rows rather than hiding any.
    public static let maxCount = 20

    /// Never empty. An unknown `activeID` falls back to the first Preset.
    public init(presets: [Preset], activeID: UUID) {
        precondition(Self.validationError(presets) == nil, "Invalid Preset List")
        self.presets = presets
        self.activeID = presets.contains { $0.id == activeID } ? activeID : presets[0].id
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case empty, tooManyPresets, duplicateIDs
    }

    private static func validationError(_ presets: [Preset]) -> ValidationError? {
        if presets.isEmpty { return .empty }
        if presets.count > maxCount { return .tooManyPresets }
        if Set(presets.map(\.id)).count != presets.count { return .duplicateIDs }
        return nil
    }

    /// The untrusted restoration boundary shared with persisted decoding.
    public static func restoring(presets: [Preset], activeID: UUID) throws -> PresetList {
        if let error = validationError(presets) { throw error }
        return PresetList(presets: presets, activeID: activeID)
    }

    /// The starter Presets, Balanced active (§4.2).
    public static var starter: PresetList {
        let presets = Preset.starters
        return PresetList(presets: presets, activeID: presets[0].id)
    }

    public var active: Preset {
        presets.first { $0.id == activeID } ?? presets[0]
    }

    public func preset(id: UUID) -> Preset? { presets.first { $0.id == id } }

    // MARK: Activate

    /// Makes the Preset the Active Preset. An unknown id changes nothing.
    public mutating func activate(_ id: UUID) {
        if presets.contains(where: { $0.id == id }) { activeID = id }
    }

    /// Activates the Preset at a 1-based position (⌘1 to ⌘9). Out of range changes nothing.
    public mutating func activate(position: Int) {
        guard position > 0, position <= presets.count else { return }
        activeID = presets[position - 1].id
    }

    // MARK: Duplicate

    /// False once the list holds `maxCount` Presets.
    public var canAdd: Bool { presets.count < Self.maxCount }

    /// The **+** button: copies the Active Preset, inserts the copy after it and activates the copy.
    @discardableResult
    public mutating func duplicateActive(materializedName: String? = nil) -> Preset {
        duplicate(activeID, materializedName: materializedName) ?? active
    }

    /// Insert a copy after the original and activate it. Return nil for an unknown ID or a full list.
    @discardableResult
    public mutating func duplicate(_ id: UUID, materializedName: String? = nil) -> Preset? {
        guard canAdd, let index = presets.firstIndex(where: { $0.id == id }) else { return nil }
        let original = presets[index]
        let copy = original.duplicated(name: copyName(for: materializedName ?? original.name))
        presets.insert(copy, at: index + 1)
        activeID = copy.id
        return copy
    }

    /// Use suffixes 2 through 9, replacing existing suffixes. Truncate the base consistently.
    /// After exhausting suffixes, wrap after the original number. Duplicate names are allowed.
    private func copyName(for name: String) -> String {
        let (base, current) = Self.split(name)
        let room = max(Preset.maxNameLength - 2, 0)
        let stem = String(base.prefix(room)).trimmingCharacters(in: .whitespaces)
        let taken = Set(presets.map(\.name))
        let numbers = Array(2...9)
        if let free = numbers.first(where: { !taken.contains("\(stem) \($0)") }) {
            return "\(stem) \(free)"
        }
        let next = current.flatMap { numbers.contains($0) && $0 < 9 ? $0 + 1 : nil } ?? 2
        return "\(stem) \(next)"
    }

    /// The name without a trailing " <number>", and that number.
    private static func split(_ name: String) -> (base: String, number: Int?) {
        let base = baseName(of: name)
        guard base != name else { return (name, nil) }
        return (base, Int(name[name.index(name.startIndex, offsetBy: base.count)...].trimmingCharacters(in: .whitespaces)))
    }

    private static func baseName(of name: String) -> String {
        guard let space = name.lastIndex(of: " ") else { return name }
        let tail = name[name.index(after: space)...]
        let head = name[..<space].trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !tail.isEmpty, tail.allSatisfy(\.isASCII), tail.allSatisfy(\.isNumber)
        else { return name }
        return head
    }

    // MARK: Delete

    /// Reject unknown IDs and deletion of the last Preset.
    /// If active, select the next Preset, or the previous Preset when deleting the last position.
    @discardableResult
    public mutating func delete(_ id: UUID) -> Bool {
        guard presets.count > 1, let index = presets.firstIndex(where: { $0.id == id }) else {
            return false
        }
        presets.remove(at: index)
        if id == activeID {
            activeID = presets[min(index, presets.count - 1)].id
        }
        return true
    }

    // MARK: Reorder

    /// Same meaning as SwiftUI's `onMove`: `toOffset` is an index in the list before the move.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.filter { presets.indices.contains($0) }.map { presets[$0] }
        guard !moving.isEmpty else { return }
        let before = source.filter { $0 < destination }.count
        var rest = presets
        for index in source.sorted(by: >) where rest.indices.contains(index) { rest.remove(at: index) }
        let target = min(max(destination - before, 0), rest.count)
        rest.insert(contentsOf: moving, at: target)
        presets = rest
    }

    /// Moves a Preset so it ends up at `index` (clamped). Unknown id changes nothing.
    public mutating func move(_ id: UUID, to index: Int) {
        guard let from = presets.firstIndex(where: { $0.id == id }) else { return }
        let preset = presets.remove(at: from)
        presets.insert(preset, at: min(max(index, 0), presets.count))
    }

    // MARK: Edit

    private mutating func edit(_ id: UUID, _ change: (inout Preset) -> Void) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        change(&presets[index])
    }

    public mutating func rename(_ id: UUID, to name: String) { edit(id) { $0.setName(name) } }
    public mutating func setQuality(_ id: UUID, to value: Int) { edit(id) { $0.setQuality(value) } }
    public mutating func setLossless(_ id: UUID, to value: Bool) { edit(id) { $0.lossless = value } }
    public mutating func setOutputFormat(_ id: UUID, to value: OutputFormat) { edit(id) { $0.outputFormat = value } }
    public mutating func setKeepMetadata(_ id: UUID, to value: Bool) { edit(id) { $0.keepMetadata = value } }
    public mutating func setResizeRule(_ id: UUID, to value: ResizeRule) { edit(id) { $0.setResizeRule(value) } }

    /// Restore name provenance from an earlier valid value during an editing session.
    public mutating func restoreName(_ id: UUID, from original: Preset) {
        guard id == original.id else { return }
        edit(id) { $0.name = original.name; $0.starterID = original.starterID }
    }
}
