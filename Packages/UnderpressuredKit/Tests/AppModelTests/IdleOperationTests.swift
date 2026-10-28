import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct IdleOperationTests {
    private func urls(_ count: Int) -> [URL] {
        (0..<count).map { URL(filePath: "/tmp/idle-\($0).jpg") }
    }

    private func model(
        pipeline: @escaping ItemPipeline,
        intake: @escaping Intake = { urls, _, _ in
            ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: 0)
        },
        updateInterval: Duration = .milliseconds(100)
    ) -> AppModel {
        AppModel(queue: Queue(parallelism: 1, pixelBudget: 1_000_000, pipeline: pipeline), intake: intake, updateInterval: updateInterval)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition())
    }

    @Test func callbackRunsOnceAfterSuccessfulDrain() async {
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        let (release, signalRelease) = AsyncStream<Void>.makeStream()
        let queueModel = model(pipeline: { _, _, executionContext, gate in
            try? await gate.enter(.decoding)
            signalStarted.yield(())
            for await _ in release { break }
            return .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: URL(filePath: "/out"))
        })
        await queueModel.open(urls(1))
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()

        var callbacks = 0
        let token = queueModel.reserveIdleOperation { callbacks += 1 }
        #expect(token != nil)
        #expect(callbacks == 0)
        signalRelease.yield(())
        await queueModel.untilIdle()
        #expect(callbacks == 1)
        queueModel.releaseIdleOperation(token!)
    }

    @Test func callbackRunsAfterCanceledAndFailedDrains() async {
        for result in [Outcome.cancelled, .failed(.encodeFailed)] {
            let (started, signalStarted) = AsyncStream<Void>.makeStream()
            let (release, signalRelease) = AsyncStream<Void>.makeStream()
            let queueModel = model(pipeline: { _, _, executionContext, gate in
                try? await gate.enter(.decoding)
                signalStarted.yield(())
                for await _ in release { break }
                return result
            })
            await queueModel.open(urls(1))
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()
            var callbacks = 0
            let token = queueModel.reserveIdleOperation { callbacks += 1 }
            #expect(callbacks == 0)
            if result == .cancelled {
                let cancel = Task { await queueModel.cancel() }
                signalRelease.yield(())
                await cancel.value
            } else {
                signalRelease.yield(())
                await queueModel.untilIdle()
            }
            #expect(callbacks == 1)
            queueModel.releaseIdleOperation(token!)
        }
    }

    @Test func reservationFlushesThrottledEventsImmediately() async {
        let time = ManualProgressTime()
        defer { time.cancelSleepers() }
        let (release, signalRelease) = AsyncStream<Void>.makeStream()
        let (secondStarted, signalSecondStarted) = AsyncStream<Void>.makeStream()
        let queueModel = AppModel(
            queue: Queue(parallelism: 2, pixelBudget: 1_000_000) { item, _, executionContext, gate in
                if item.source.lastPathComponent == "idle-1.jpg" {
                    try? await gate.enter(.decoding)
                    signalSecondStarted.yield(())
                    for await _ in release { break }
                }
                return .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: URL(filePath: "/out"))
            },
            intake: { urls, _, _ in ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: 0) },
            updateInterval: .seconds(30), progressTime: time)
        await queueModel.open(urls(2))
        var iterator = secondStarted.makeAsyncIterator()
        _ = await iterator.next()
        // Admission flush reads the clock twice; both processing events and the
        // first terminal event must enter the buffer before testing its forced flush.
        await waitUntil { time.readCount >= 5 }
        let before = queueModel.appliedUpdateCount
        let token = queueModel.reserveIdleOperation {}
        #expect(token != nil)
        #expect(queueModel.appliedUpdateCount > before)
        #expect(queueModel.rows.contains(where: { $0.name == "idle-0.jpg" && $0.stateText == "Optimized" }))
        signalRelease.yield(())
        await queueModel.untilIdle()
        queueModel.releaseIdleOperation(token!)
    }

    @Test func intakeWaitsUntilReservationReleasedEvenAfterCallback() async {
        let queueModel = model(pipeline: { _, _, executionContext, _ in .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: URL(filePath: "/out")) })
        var callbacks = 0
        let token = queueModel.reserveIdleOperation { callbacks += 1 }
        #expect(callbacks == 1)
        let intake = Task { await queueModel.open([URL(filePath: "/tmp/queued.jpg")]) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(queueModel.rows.isEmpty)
        queueModel.releaseIdleOperation(token!)
        await intake.value
        await queueModel.untilIdle()
        #expect(queueModel.rows.map(\.name) == ["queued.jpg"])
        #expect(callbacks == 1)
    }

    @Test func staleAndDoubleReleaseCannotReleaseNewReservation() async {
        let queueModel = model(pipeline: { _, _, executionContext, _ in .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: URL(filePath: "/out")) })
        let first = queueModel.reserveIdleOperation {}
        queueModel.releaseIdleOperation(first!)
        queueModel.releaseIdleOperation(first!)
        var secondCallback = 0
        let second = queueModel.reserveIdleOperation { secondCallback += 1 }
        #expect(second != nil)
        #expect(secondCallback == 1)

        queueModel.releaseIdleOperation(first!)
        let intake = Task { await queueModel.open([URL(filePath: "/tmp/stale.jpg")]) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(queueModel.rows.isEmpty)
        queueModel.releaseIdleOperation(second!)
        await intake.value
        await queueModel.untilIdle()
        #expect(queueModel.rows.map(\.name) == ["stale.jpg"])
    }

    @Test func intakeQueuedBeforeQuitCannotStartAfterReservationRelease() async {
        let queueModel = model(pipeline: { _, _, executionContext, _ in .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: URL(filePath: "/out")) })
        let token = queueModel.reserveIdleOperation {}
        let intake = Task { await queueModel.open([URL(filePath: "/tmp/quit-queued.jpg")]) }
        try? await Task.sleep(for: .milliseconds(20))
        let quitting = Task { await queueModel.cancelForQuit() }
        await quitting.value
        queueModel.releaseIdleOperation(token!)
        await intake.value
        #expect(queueModel.rows.isEmpty)
    }
}
