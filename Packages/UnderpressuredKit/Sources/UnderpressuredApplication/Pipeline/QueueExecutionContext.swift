import UnderpressuredCore
import Foundation
import Synchronization

/// Output reservations and folder checks for batches received since the Queue was last idle.
/// The Queue retires mutable state after every item has returned, including cancelled items.
public final class QueueExecutionContext: Sendable {
    private struct State {
        var planner: OutputPathPlanner?
        var exportFolderAvailability: [Batch.ID: Bool] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Checked once per batch, since batches can capture different destinations.
    func exportFolderAvailable(_ batchID: Batch.ID, check: () -> Bool) -> Bool {
        state.withLock { state in
            if let known = state.exportFolderAvailability[batchID] { return known }
            let available = check()
            state.exportFolderAvailability[batchID] = available
            return available
        }
    }

    /// Only path planning holds this lock; codec work and file commits happen outside it.
    func plan(
        files: any FileAccess,
        _ body: (inout OutputPathPlanner) throws(FileAccessError) -> OutputPlan
    ) throws(FileAccessError) -> OutputPlan {
        try state.withLock { (state: inout State) throws(FileAccessError) -> OutputPlan in
            if state.planner == nil { state.planner = OutputPathPlanner(fileAccess: files) }
            return try body(&state.planner!)
        }
    }

    /// Release interval resources after all workers return.
    func retire() { state.withLock { $0 = State() } }

    var cachedBatchCount: Int { state.withLock { $0.exportFolderAvailability.count } }
    var reservedPathCount: Int { state.withLock { $0.planner?.reservedPathCount ?? 0 } }
}
