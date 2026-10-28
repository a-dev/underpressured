import UnderpressuredCore
import Foundation
import Synchronization

/// What the Queue publishes. Consumers (the App's model) fold these into their own state.
public enum QueueEvent: Sendable, Hashable {
    case batchAdded(Batch)
    case itemChanged(batchID: Batch.ID, itemID: Item.ID, state: ItemState)
    /// Nothing is Waiting or Processing any more.
    case idle
}

/// Lets a pipeline report its stage, and stops it at the next stage boundary after Cancel (§7.6).
public struct StageGate: Sendable {
    let enter: @Sendable (Stage) async throws(CancellationError) -> Void
    let didCommit: @Sendable () -> Void
    let reservePixels: @Sendable (Int) async throws(CancellationError) -> Void

    init(
        enter: @escaping @Sendable (Stage) async throws(CancellationError) -> Void,
        didCommit: @escaping @Sendable () -> Void = {},
        reservePixels: @escaping @Sendable (Int) async throws(CancellationError) -> Void = { _ in }
    ) {
        self.didCommit = didCommit
        self.enter = enter
        self.reservePixels = reservePixels
    }

    /// Record a successful filesystem rename before returning its outcome.
    func committed() { didCommit() }

    /// Call before each stage. Throws once the Item has been cancelled.
    public func enter(_ stage: Stage) async throws(CancellationError) {
        try await enter(stage)
    }

    /// Call once before decoding with the pixel count. Wait for budget capacity. Throw after cancellation.
    /// Release the reservation when the Item finishes.
    public func reservePixels(_ pixels: Int) async throws(CancellationError) {
        try await reservePixels(pixels)
    }
}

/// Processes one Item into an Outcome.
public typealias ItemPipeline = @Sendable (Item, BatchContext, QueueExecutionContext, StageGate) async -> Outcome

/// The Batches waiting or in progress, processed in drop order (spec §7.1, §7.6, §7.7).
public actor Queue {
    public nonisolated let events: AsyncStream<QueueEvent>
    private let continuation: AsyncStream<QueueEvent>.Continuation
    private let pipeline: ItemPipeline
    /// Items running at once: the performance-core count in the app (§7.7).
    public let parallelism: Int
    /// Limits decoded pixels in flight. An image above the budget runs alone.
    public let pixelBudget: Int
    /// Allows about 3.6 GB at the measured peak of 30 bytes per source pixel.
    /// Fits ten 12 MP photos or two 48 MP images.
    public static let defaultPixelBudget = 120_000_000

    private var executionContext: QueueExecutionContext?
    private struct Execution {
        var item: Item
        let batchID: Batch.ID
        let order: Int
    }
    private struct ExecutionBatch {
        let context: BatchContext
        let ignoredCount: Int
        var remaining: Int
    }
    private var items: [Item.ID: Execution] = [:]
    private var batches: [Batch.ID: ExecutionBatch] = [:]
    private var waiting = FIFO<Item.ID>()
    private var nextOrder = 0
    private var work = SchedulerWork()

    /// Counts logical scheduler operations, independent of timing and allocator behavior.
    public struct SchedulerWork: Sendable {
        public fileprivate(set) var admissions = 0
        public fileprivate(set) var waitingVisits = 0
        public fileprivate(set) var stateLookups = 0
        public fileprivate(set) var finishes = 0
        public fileprivate(set) var pixelWaiterVisits = 0
    }
    public struct Diagnostics: Sendable {
        public let items: Int
        public let batches: Int
        public let waitingSlots: Int
        public let pixelWaiterSlots: Int
        public let activeSources: Int
        public let reservedPaths: Int
        public let cachedBatches: Int
        public let hasExecutionContext: Bool
        public let work: SchedulerWork
    }
    public var diagnostics: Diagnostics {
        Diagnostics(items: items.count, batches: batches.count, waitingSlots: waiting.storageCount,
                    pixelWaiterSlots: pixelWaiters.storageCount, activeSources: activeSources.count,
                    reservedPaths: executionContext?.reservedPathCount ?? 0,
                    cachedBatches: executionContext?.cachedBatchCount ?? 0,
                    hasExecutionContext: executionContext != nil, work: work)
    }
    private var running: Set<Item.ID> = []
    private var activeSources: Set<SourceIdentity.Key> = []
    private var cancelRequested: Set<Item.ID> = []
    /// Pixels reserved by Items that are Processing.
    private(set) var pixelsInFlight = 0
    private var reservations: [Item.ID: Int] = [:]
    /// Serve reservations in arrival order so smaller images cannot delay a waiting large image indefinitely.
    private var pixelWaiters = FIFO<PixelWaiter>()
    var pixelWaiterCount: Int { pixelWaiters.count }

    private struct PixelWaiter {
        let itemID: Item.ID
        let cost: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    public init(parallelism: Int, pixelBudget: Int = Queue.defaultPixelBudget, pipeline: @escaping ItemPipeline) {
        precondition(parallelism > 0 && pixelBudget > 0)
        self.parallelism = parallelism
        self.pixelBudget = pixelBudget
        self.pipeline = pipeline
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit { continuation.finish() }

    /// Adds a Batch at the end; it starts after every earlier Batch has started (§7.1).
    /// Reject identity collisions before reserving sources or publishing admission.
    @discardableResult
    public func enqueue(_ batch: Batch) -> Bool {
        // This runs in the caller's task, in the same actor turn as admission.
        // If admission already happened, cancel() visits it; otherwise reject it here.
        guard !Task.isCancelled, batches[batch.id] == nil else { return false }
        var candidateIDs: Set<Item.ID> = []
        for item in batch.items {
            guard candidateIDs.insert(item.id).inserted, items[item.id] == nil else { return false }
        }
        var batch = batch
        // Admission and reservation occur in one actor turn, before any pipeline can finish.
        for i in batch.items.indices {
            switch batch.items[i].state {
            case .waiting, .finished(.skipped(.alreadyInQueue, _, _)):
                let identity = batch.items[i].sourceIdentity
                if activeSources.isDisjoint(with: identity.keys) {
                    activeSources.formUnion(identity.keys)
                    batch.items[i].state = .waiting
                } else {
                    batch.items[i].state = .finished(.skipped(.alreadyInQueue, notes: []))
                }
            default: break
            }
        }
        executionContext = executionContext ?? QueueExecutionContext()
        // Publish the captured admission value once; worker mutations never touch its array.
        continuation.yield(.batchAdded(batch))
        let unfinishedCount = batch.items.count { !$0.state.isFinished }
        if unfinishedCount > 0 {
            batches[batch.id] = ExecutionBatch(context: batch.context, ignoredCount: batch.ignoredCount,
                                               remaining: unfinishedCount)
            for item in batch.items where !item.state.isFinished {
                items[item.id] = Execution(item: item, batchID: batch.id, order: nextOrder)
                nextOrder += 1
                work.admissions += 1
                waiting.append(item.id)
            }
        }
        startAvailable()
        reportIdleIfDone()
        return true
    }

    /// Cancel Waiting Items immediately and Processing Items at the next stage boundary. Preserve finished Items.
    public func cancel() {
        while let id = waiting.popFirst() {
            work.waitingVisits += 1
            setState(.finished(.cancelled), itemID: id)
        }
        cancelRequested.formUnion(running)
        // An Item waiting for pixels is at a stage boundary: it stops now.
        while let waiter = pixelWaiters.popFirst() { waiter.continuation.resume(returning: false) }
        reportIdleIfDone()
    }

    /// Unfinished execution only, in admission order. Finished rows belong to event consumers.
    /// Terminal events are yielded before their records are removed. The stream buffers them
    /// until consumed; taking a snapshot does not consume or acknowledge events.
    /// This explicit diagnostic query is O(active items log active items); scheduling never uses it.
    public var snapshot: [Batch] {
        var result: [Batch] = []
        for record in items.values.sorted(by: { $0.order < $1.order }) {
            if result.last?.id == record.batchID {
                result[result.count - 1].items.append(record.item)
            } else if let batch = batches[record.batchID] {
                let context = batch.context
                let value = Batch(id: context.id, settings: context.settings, outputFormat: context.outputFormat,
                                  destination: context.destination, items: [record.item],
                                  ignoredCount: batch.ignoredCount, presetName: context.presetName)
                result.append(value)
            }
        }
        return result
    }

    /// Whether a normalized path is Waiting or Processing. For aliases, pass the Scanner's identity.
    public func isActive(_ source: URL) -> Bool {
        isActive(SourceIdentity(source: source))
    }

    public func isActive(_ identity: SourceIdentity) -> Bool {
        !activeSources.isDisjoint(with: identity.keys)
    }

    // MARK: Scheduling

    private func startAvailable() {
        while running.count < parallelism, let id = waiting.popFirst() {
            work.waitingVisits += 1
            guard let record = items[id], let context = batches[record.batchID]?.context,
                  let executionContext else { continue }
            let item = record.item
            running.insert(id)
            setState(.processing(.checkingMark), itemID: id)
            let committed = Mutex(false)
            let gate = StageGate(
                enter: { [weak self] stage throws(CancellationError) in
                    guard let self else { throw CancellationError() }
                    try await self.enter(stage, itemID: id)
                },
                didCommit: { committed.withLock { $0 = true } },
                reservePixels: { [weak self] pixels throws(CancellationError) in
                    guard let self else { throw CancellationError() }
                    try await self.reserve(pixels, itemID: id)
                })
            let pipeline = pipeline
            Task {
                let outcome = await pipeline(item, context, executionContext, gate)
                self.finish(id, outcome: outcome, committed: committed.withLock { $0 })
            }
        }
    }

    private func enter(_ stage: Stage, itemID: Item.ID) throws(CancellationError) {
        if cancelRequested.contains(itemID) || items[itemID] == nil { throw CancellationError() }
        setState(.processing(stage), itemID: itemID)
    }

    // MARK: Pixel budget

    private func reserve(_ pixels: Int, itemID: Item.ID) async throws(CancellationError) {
        if cancelRequested.contains(itemID) { throw CancellationError() }
        let cost = min(max(pixels, 1), pixelBudget)
        if pixelWaiters.isEmpty, pixelsInFlight + cost <= pixelBudget {
            grant(cost, to: itemID)
            return
        }
        let granted = await withCheckedContinuation { continuation in
            pixelWaiters.append(PixelWaiter(itemID: itemID, cost: cost, continuation: continuation))
        }
        if !granted { throw CancellationError() }
    }

    private func grant(_ cost: Int, to itemID: Item.ID) {
        pixelsInFlight += cost
        reservations[itemID, default: 0] += cost
    }

    private func release(_ itemID: Item.ID) {
        pixelsInFlight -= reservations.removeValue(forKey: itemID) ?? 0
        while let head = pixelWaiters.first, pixelsInFlight + head.cost <= pixelBudget {
            _ = pixelWaiters.popFirst()
            work.pixelWaiterVisits += 1
            grant(head.cost, to: head.itemID)
            head.continuation.resume(returning: true)
        }
    }

    private func finish(_ itemID: Item.ID, outcome: Outcome, committed: Bool) {
        running.remove(itemID)
        release(itemID)
        work.finishes += 1
        let cancelled = cancelRequested.remove(itemID) != nil
        // Keep write failures: Trash-first writes can have side effects before rename fails.
        let writeFailed: Bool
        if case .failed = outcome, items[itemID]?.item.state == .processing(.writing) {
            writeFailed = true
        } else { writeFailed = false }
        let final = cancelled && !committed && !writeFailed ? .cancelled : outcome
        setState(.finished(final), itemID: itemID)
        startAvailable()
        reportIdleIfDone()
    }

    private func setState(_ state: ItemState, itemID: Item.ID) {
        work.stateLookups += 1
        guard var record = items[itemID], record.item.state != state else { return }
        record.item.state = state
        continuation.yield(.itemChanged(batchID: record.batchID, itemID: itemID, state: state))
        if state.isFinished {
            activeSources.subtract(record.item.sourceIdentity.keys)
            items.removeValue(forKey: itemID)
            batches[record.batchID]!.remaining -= 1
            if batches[record.batchID]!.remaining == 0 { batches.removeValue(forKey: record.batchID) }
        } else {
            items[itemID] = record
        }
    }

    private func reportIdleIfDone() {
        if running.isEmpty, items.isEmpty {
            executionContext?.retire()
            executionContext = nil
            nextOrder = 0
            // Release dictionary capacity as well as records between independent runs.
            items = [:]
            batches = [:]
            activeSources = []
            cancelRequested = []
            reservations = [:]
            continuation.yield(.idle)
        }
    }
}

/// A consumed slot releases its value immediately. Periodic compaction is amortized O(1).
private struct FIFO<Element> {
    private var storage: [Element?] = []
    private var head = 0
    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }
    var storageCount: Int { storage.count }
    var first: Element? { isEmpty ? nil : storage[head] }
    mutating func append(_ value: Element) { storage.append(value) }
    mutating func popFirst() -> Element? {
        guard head < storage.count else { return nil }
        let value = storage[head]
        storage[head] = nil
        head += 1
        if head == storage.count {
            storage = []
            head = 0
        } else if head >= 1024 && head >= storage.count / 2 {
            storage.removeFirst(head)
            head = 0
        }
        return value
    }
}
