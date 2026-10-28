import UnderpressuredApplication
import Foundation
import UnderpressuredCore

/// Buffers Queue events to limit main-actor updates to about ten per second.
final class PendingEvents: @unchecked Sendable {
    enum Plan: Sendable {
        /// A flush is already scheduled.
        case wait
        case now
        case after(ContinuousClock.Instant)
    }

    private let time: any ProgressTime

    init(time: any ProgressTime = ContinuousProgressTime()) { self.time = time }

    private let lock = NSLock()
    private var events: [QueueEvent] = []
    private var flushScheduled = false
    private var lastFlush: ContinuousClock.Instant?

    /// Flush immediately after a quiet period or on `.idle`. Otherwise, wait for `interval`.
    func add(_ event: QueueEvent, interval: Duration) -> Plan {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
        let now = time.now
        let remaining = lastFlush.map { $0 + interval - now } ?? .zero
        // A scheduled flush is about to fire; piling a second one on top would double the rate.
        if flushScheduled, event != .idle { return .wait }
        if event == .idle || remaining <= .zero {
            lastFlush = now
            flushScheduled = false
            return .now
        }
        flushScheduled = true
        return .after(now + remaining)
    }

    func take() -> [QueueEvent] {
        lock.lock()
        defer { lock.unlock() }
        lastFlush = time.now
        flushScheduled = false
        defer { events = [] }
        return events
    }
}
