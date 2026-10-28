import UnderpressuredApplication
/// Shared time for progress throttling decisions and the trailing flush deadline.
protocol ProgressTime: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

struct ContinuousProgressTime: ProgressTime {
    var now: ContinuousClock.Instant { ContinuousClock.now }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await ContinuousClock().sleep(until: deadline)
    }
}
