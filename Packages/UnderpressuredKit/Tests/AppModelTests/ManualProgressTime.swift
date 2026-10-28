import UnderpressuredApplication
import Foundation
import Synchronization
@testable import AppModel

/// Only advances when requested. Registration and clock reads are observable fences, so
/// tests do not guess how many executor yields an event consumer needs.
final class ManualProgressTime: ProgressTime, Sendable {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct State {
        var now = ContinuousClock.now
        var reads = 0
        var closed = false
        var sleepers: [UUID: Sleeper] = [:]
    }
    private let state = Mutex(State())

    var now: ContinuousClock.Instant {
        state.withLock { $0.reads += 1; return $0.now }
    }
    var readCount: Int { state.withLock { $0.reads } }
    var deadlines: [ContinuousClock.Instant] { state.withLock { $0.sleepers.values.map(\.deadline) } }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                state.withLock {
                    if Task.isCancelled || $0.closed {
                        continuation.resume(throwing: CancellationError())
                    } else if deadline <= $0.now {
                        continuation.resume()
                    } else {
                        $0.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    }
                }
            }
        } onCancel: {
            self.state.withLock { $0.sleepers.removeValue(forKey: id) }?
                .continuation.resume(throwing: CancellationError())
        }
    }

    func advance(to instant: ContinuousClock.Instant) {
        let ready = state.withLock {
            precondition(instant >= $0.now)
            $0.now = instant
            let ready = $0.sleepers.filter { $0.value.deadline <= instant }
            for id in ready.keys { $0.sleepers.removeValue(forKey: id) }
            return ready.values.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }

    func cancelSleepers() {
        let pending = state.withLock {
            $0.closed = true
            let pending = $0.sleepers.values.map(\.continuation)
            $0.sleepers.removeAll()
            return pending
        }
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}
