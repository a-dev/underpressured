import Foundation

/// One intake with immutable captured settings and value-owned item rows.
public struct Batch: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let settings: EffectiveSettings
    public let outputFormat: OutputFormat
    public let destination: Destination
    /// Intake candidates or a consumer-owned projection; Queue keeps its own execution records.
    public var items: [Item]
    /// Non-image files found in the drop: counted for the banner, never listed (§7.2).
    public let ignoredCount: Int
    /// The Active Preset's name at drop time, for the list's group header (§3.3).
    public let presetName: String

    public init(
        id: UUID = UUID(), settings: EffectiveSettings, outputFormat: OutputFormat,
        destination: Destination, items: [Item], ignoredCount: Int = 0, presetName: String = ""
    ) {
        self.id = id
        self.presetName = presetName
        self.settings = settings
        self.outputFormat = outputFormat
        self.destination = destination
        self.items = items
        self.ignoredCount = ignoredCount
    }
}

/// Immutable worker input. It deliberately has no item array or execution state.
public struct BatchContext: Sendable, Hashable, Identifiable {
    public let id: Batch.ID
    public let settings: EffectiveSettings
    public let outputFormat: OutputFormat
    public let destination: Destination
    public let presetName: String

    public init(_ batch: Batch) {
        id = batch.id
        settings = batch.settings
        outputFormat = batch.outputFormat
        destination = batch.destination
        presetName = batch.presetName
    }
}

extension Batch {
    public var context: BatchContext { BatchContext(self) }
}

/// One image file within a Batch.
public struct Item: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let source: URL
    public let sourceIdentity: SourceIdentity
    /// Dropped root folder, or nil for a loose file.
    /// Export paths mirror `<Export>/<root name>/<relative path>`.
    public let droppedRoot: URL?
    /// Set when the scan already decided the Outcome (unsupported, already in the queue).
    public var state: ItemState

    public init(
        id: UUID = UUID(), source: URL, droppedRoot: URL?, state: ItemState = .waiting,
        sourceAttributes: FileAttributes? = nil, sourceCaseSensitive: Bool = true
    ) {
        self.id = id
        self.source = source
        self.sourceIdentity = SourceIdentity(
            source: source, attributes: sourceAttributes, caseSensitive: sourceCaseSensitive)
        self.droppedRoot = droppedRoot
        self.state = state
    }
}

/// Where an Item is in its life: Waiting → Processing → an Outcome.
public enum ItemState: Sendable, Hashable {
    case waiting
    case processing(Stage)
    case finished(Outcome)

    public var isFinished: Bool {
        if case .finished = self { true } else { false }
    }
}

/// The steps of the pipeline (spec §7.3). Cancel takes effect at the boundary between two stages.
public enum Stage: Sendable, Hashable, CaseIterable {
    case checkingMark
    case decoding
    case transforming
    case encoding
    case writing
}
