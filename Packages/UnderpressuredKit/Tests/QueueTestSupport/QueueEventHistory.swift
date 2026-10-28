import UnderpressuredApplication
import UnderpressuredCore

/// Test-owned copy of queue rows, reconstructed from the public event stream.
public struct QueueEventHistory: Sendable {
    public private(set) var batches: [Batch] = []

    public init() {}

    public mutating func apply(_ event: QueueEvent) {
        switch event {
        case .batchAdded(let batch):
            batches.append(batch)
        case .itemChanged(let batchID, let itemID, let state):
            guard let batchIndex = batches.firstIndex(where: { $0.id == batchID }),
                  let itemIndex = batches[batchIndex].items.firstIndex(where: { $0.id == itemID }) else { return }
            batches[batchIndex].items[itemIndex].state = state
        case .idle:
            break
        }
    }

    public mutating func apply(_ events: [QueueEvent]) {
        for event in events { apply(event) }
    }

    public static func collect(untilIdle stream: AsyncStream<QueueEvent>) async -> Self {
        var history = Self()
        for await event in stream {
            history.apply(event)
            if event == .idle { break }
        }
        return history
    }
}

/// One continuous event consumer for tests that inspect history across several queue states.
public actor QueueEventRecorder {
    private var history = QueueEventHistory()
    private var idleCount = 0
    private var idleClaimed = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var batchWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    public static func observe(_ stream: AsyncStream<QueueEvent>) -> QueueEventRecorder {
        let recorder = QueueEventRecorder()
        Task {
            for await event in stream { await recorder.record(event) }
        }
        return recorder
    }

    private func record(_ event: QueueEvent) {
        history.apply(event)
        if event == .idle {
            idleCount += 1
            let waiters = idleWaiters
            idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        let ready = batchWaiters.filter { $0.0 <= history.batches.count }
        batchWaiters.removeAll { $0.0 <= history.batches.count }
        ready.forEach { $0.1.resume() }
    }

    public func waitUntilIdle() async {
        let target = idleClaimed + 1
        if idleCount < target {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        idleClaimed = target
    }

    public func waitForBatchCount(_ count: Int) async {
        if history.batches.count < count {
            await withCheckedContinuation { batchWaiters.append((count, $0)) }
        }
    }

    public var batches: [Batch] { history.batches }
}
