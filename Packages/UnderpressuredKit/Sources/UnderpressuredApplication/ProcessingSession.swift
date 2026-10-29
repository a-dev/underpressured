import Foundation
import UnderpressuredCore

/// Coordinates one product Run across serialized scans and queue execution intervals.
/// Queue remains the sole owner of item execution, reservations and resource accounting.
@MainActor
public final class ProcessingSession {
    public struct Capture: Sendable {
        public let preset: Preset
        public let outputFormat: OutputFormat
        public let destination: Destination

        public init(preset: Preset, outputFormat: OutputFormat, destination: Destination) {
            self.preset = preset
            self.outputFormat = outputFormat
            self.destination = destination
        }
    }

    public struct Activity: Sendable, Equatable {
        public let pendingScans: Int
        public let pendingAdmissions: Int
        public let unfinishedItems: Int
        public let isRunning: Bool
    }

    public enum Event: Sendable {
        case runStarted
        case activity(Activity)
        case scanFailures([ScanFailure])
        /// The user granted the captured Export folder, so a saved bookmark can now include access.
        case exportFolderGranted
        case queue(QueueEvent)
    }

    /// Events are delivered in order, before any exclusive idle callback.
    public var onEvent: (@MainActor (Event) -> Void)?
    public var activity: Activity {
        Activity(pendingScans: requests.count, pendingAdmissions: expectedBatches.count, unfinishedItems: unfinished.count,
                 isRunning: !requests.isEmpty || !expectedBatches.isEmpty || !unfinished.isEmpty)
    }
    private var intakeSequence = 0

    private let queue: Queue
    private let intake: Intake
    private let folderAccess: any FolderAccess
    private var generation = 0
    private var requests: [Int: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    private var expectedBatches: Set<Batch.ID> = []
    private var unfinished: Set<Item.ID> = []
    private var lastActivity = Activity(pendingScans: 0, pendingAdmissions: 0, unfinishedItems: 0, isRunning: false)
    private var idleOperation: (id: UUID, action: (@MainActor () -> Void)?)?
    private var admissionWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var eventTask: Task<Void, Never>?

    public init(queue: Queue, intake: @escaping Intake, folderAccess: any FolderAccess = UnrestrictedFolderAccess()) {
        self.queue = queue
        self.intake = intake
        self.folderAccess = folderAccess
        let events = queue.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.receive(event)
            }
        }
    }

    isolated deinit { eventTask?.cancel() }

    /// Captures settings after admission is unlocked and before scanning starts.
    /// Before scanning, asks for an Export folder the app cannot write.
    /// Between scan and admission, asks for folders that converted loose files need.
    public func open(_ urls: [URL], capture: @MainActor () -> Capture?) async {
        let admissionGeneration = generation
        while idleOperation != nil {
            await withCheckedContinuation { admissionWaiters.append($0) }
        }
        guard admissionGeneration == generation, !Task.isCancelled,
              !urls.isEmpty, let captured = capture() else { return }
        let startsRun = !activity.isRunning
        let sequence = intakeSequence
        intakeSequence += 1
        let scanGeneration = generation
        let previous = tail
        let task = Task { [self] in
            defer {
                requests.removeValue(forKey: sequence)
                if intakeSequence == sequence + 1 { tail = nil }
                publishActivity()
            }
            await previous?.value
            guard scanGeneration == generation, !Task.isCancelled else { return }
            let exportFolder: URL? = if case .exportFolder(let url) = captured.destination { url } else { nil }
            if let exportFolder, !folderAccess.canCreateFiles(in: exportFolder) {
                await folderAccess.requestAccess(to: exportFolder, for: .exportFolder)
                guard scanGeneration == generation, !Task.isCancelled else { return }
                if folderAccess.canCreateFiles(in: exportFolder) { onEvent?(.exportFolderGranted) }
            }
            let intake = intake
            // The scanner blocks on filesystem calls, so it runs outside the cooperative pool.
            let result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: intake(urls, exportFolder, { _ in false }))
                }
            }
            guard scanGeneration == generation, !Task.isCancelled else { return }
            let folders = SiblingOutputFolders.needed(
                for: result.items, outputFormat: captured.outputFormat, destination: captured.destination)
            // Checked per folder: granting one folder can cover the next.
            for folder in folders where !folderAccess.canCreateFiles(in: folder) {
                await folderAccess.requestAccess(to: folder, for: .siblingOutputs)
                guard scanGeneration == generation, !Task.isCancelled else { return }
            }
            onEvent?(.scanFailures(result.failures))
            let batch = Batch(activePreset: captured.preset, outputFormat: captured.outputFormat,
                              destination: captured.destination, items: result.items, ignoredCount: result.ignoredCount)
            expectedBatches.insert(batch.id)
            if !(await queue.enqueue(batch)) { expectedBatches.remove(batch.id) }
        }
        requests[sequence] = task
        tail = task
        if startsRun { onEvent?(.runStarted) }
        publishActivity()
        await task.value
    }

    public func cancel() async {
        generation += 1
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
        tail = nil
        await queue.cancel()
        publishActivity()
    }

    /// Locks admission synchronously; presentation throttling cannot postpone this lock.
    public func reserveIdleOperation(_ action: @escaping @MainActor () -> Void) -> UUID? {
        guard idleOperation == nil else { return nil }
        let id = UUID()
        idleOperation = (id, action)
        runIdleOperationIfReady()
        return id
    }

    public func releaseIdleOperation(_ id: UUID) {
        guard idleOperation?.id == id else { return }
        idleOperation = nil
        let waiters = admissionWaiters
        admissionWaiters = []
        waiters.forEach { $0.resume() }
    }

    public func untilIdle() async {
        if !activity.isRunning { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func receive(_ event: QueueEvent) {
        switch event {
        case .batchAdded(let batch):
            expectedBatches.remove(batch.id)
            unfinished.formUnion(batch.items.filter { !$0.state.isFinished }.map(\.id))
        case .itemChanged(_, let id, let state):
            if state.isFinished { unfinished.remove(id) }
        case .idle: break
        }
        onEvent?(.queue(event))
        publishActivity()
    }

    private func publishActivity() {
        let value = activity
        if lastActivity != value {
            lastActivity = value
            onEvent?(.activity(value))
        }
        if !value.isRunning {
            let waiters = idleWaiters
            idleWaiters = []
            waiters.forEach { $0.resume() }
            runIdleOperationIfReady()
        }
    }

    private func runIdleOperationIfReady() {
        guard !activity.isRunning, let action = idleOperation?.action else { return }
        idleOperation?.action = nil
        action()
    }
}
