import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

/// A model on a real Queue with a chosen update interval; `pipeline` decides each Item's fate.
@MainActor
private func throttledModel(
    interval: Duration, parallelism: Int = 4, pipeline: @escaping ItemPipeline
) -> AppModel {
    AppModel(
        queue: Queue(parallelism: parallelism, pixelBudget: 1_000_000, pipeline: pipeline),
        intake: { urls, _, _ in ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: 0) },
        updateInterval: interval)
}

private let quick: ItemPipeline = { _, _, executionContext, _ in .optimized(Savings(originalBytes: 1_000, newBytes: 400), notes: [], output: URL(filePath: "/out")) }

private func urls(_ range: Range<Int>) -> [URL] { range.map { URL(filePath: "/tmp/\($0).jpg") } }

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let limit = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < limit, !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ThrottleTests {
    @Test func tenThousandFastItemsCauseFarFewerUpdatesAndAnExactEnd() async {
        let model = throttledModel(interval: .milliseconds(100), pipeline: quick)
        let start = ContinuousClock.now
        await model.open(urls(0..<10_000))
        await model.untilIdle()
        let seconds = Double((ContinuousClock.now - start).components.seconds)
            + Double((ContinuousClock.now - start).components.attoseconds) / 1e18

        print("throttle: \(model.appliedUpdateCount) updates in \(seconds) s for 10000 items")
        #expect(model.appliedUpdateCount >= 2)
        #expect(Double(model.appliedUpdateCount) <= seconds * 10 + 3)
        #expect(model.appliedUpdateCount < 1_000)
        #expect(model.rows.count == 10_000)
        #expect(model.rows.allSatisfy { $0.stateText == "Optimized" })
        #expect(model.remainingCount == 0)
        #expect(!model.isRunning)
        #expect(model.banner?.text.hasPrefix("\(10000.formatted()) images · ") == true)
        #expect(model.footer.savingsText == nil)
    }

    @Test func trailingCompletionAppearsAtDeadlineWhileOtherItemIsActive() async throws {
        let time = ManualProgressTime()
        let first = AsyncStream<Void>.makeStream()
        let second = AsyncStream<Void>.makeStream()
        defer {
            first.continuation.finish()
            second.continuation.finish()
            time.cancelSleepers()
        }
        let model = AppModel(
            queue: Queue(parallelism: 2, pixelBudget: 1_000_000) { item, _, executionContext, _ in
                let stream = item.source.lastPathComponent == "0.jpg" ? first.stream : second.stream
                for await _ in stream { break }
                return .optimized(Savings(originalBytes: 1_000, newBytes: 400), notes: [], output: URL(filePath: "/out"))
            },
            intake: { urls, _, _ in ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }) },
            updateInterval: .milliseconds(100), progressTime: time)
        await model.open(urls(0..<2))
        // The immediate admission flush creates both rows. Buffer both processing events
        // (one clock read each) before releasing a completion into the same burst.
        try #require(await eventually { time.readCount >= 4 && time.deadlines.count == 1 })
        let initialDeadline = try #require(time.deadlines.first)
        #expect(model.rows.count == 2)

        let reads = time.readCount
        first.continuation.finish()
        try #require(await eventually { time.readCount > reads && time.deadlines.count == 1 })
        let deadline = try #require(time.deadlines.first)
        #expect(deadline == initialDeadline)
        #expect(model.rows.allSatisfy { $0.stateText != "Optimized" })
        time.advance(to: deadline - .nanoseconds(1))
        #expect(model.rows.allSatisfy { $0.stateText != "Optimized" })
        #expect(time.deadlines == [deadline])
        time.advance(to: deadline)

        // Bounded observation fails on a missing trailing flush, then defer releases all work.
        try #require(await eventually { model.rows.first?.stateText == "Optimized" },
                     "Trailing completion must be visible before idle")
        #expect(model.rows.count == 2)
        #expect(model.rows[1].isProcessing)
        #expect(model.remainingCount == 1)
        #expect(model.isRunning)

        // Idle must bypass the next interval; virtual time stays at the same instant.
        second.continuation.finish()
        try #require(await eventually { !model.isRunning })
        #expect(model.rows.allSatisfy { $0.stateText == "Optimized" })
        #expect(model.remainingCount == 0)
        try #require(await eventually { time.deadlines.isEmpty })
    }

    @Test func aDropDuringARunJoinsItAndTheFinalCountsAreExact() async {
        let (stream, hold) = AsyncStream<Void>.makeStream()
        let model = throttledModel(interval: .milliseconds(100), parallelism: 1) { item, _, executionContext, gate in
            if item.source.lastPathComponent == "0.jpg" {
                try? await gate.enter(.decoding)
                for await _ in stream { break }
            }
            return .optimized(Savings(originalBytes: 1_000, newBytes: 400), notes: [], output: URL(filePath: "/out"))
        }
        await model.open(urls(0..<3))
        await model.open(urls(3..<8))
        #expect(model.isRunning)
        hold.yield()
        await model.untilIdle()

        #expect(model.rows.count == 8)
        #expect(model.banner?.text.hasPrefix("8 images · ") == true)
        #expect(model.footer.savingsText == nil)
    }

    @Test func quitDecisionCountsPendingUpdatesEvenWithALongInterval() async {
        let (stream, hold) = AsyncStream<Void>.makeStream()
        // Item 0 finishes at once, the rest wait: the "finished" event is throttled away.
        let model = throttledModel(interval: .seconds(30), parallelism: 2) { item, _, executionContext, gate in
            if item.source.lastPathComponent != "0.jpg" {
                try? await gate.enter(.decoding)
                for await _ in stream { break }
            }
            return .optimized(Savings(originalBytes: 1_000, newBytes: 400), notes: [], output: URL(filePath: "/out"))
        }
        await model.open(urls(0..<3))
        var decision = model.quitDecision
        for _ in 0..<400 where decision != .confirm(message: "Cancel 2 remaining images and quit?") {
            try? await Task.sleep(for: .milliseconds(5))
            decision = model.quitDecision
        }
        #expect(decision == .confirm(message: "Cancel 2 remaining images and quit?"))

        // Processing Items stop at a stage boundary; these two sit in the pipeline until released.
        hold.yield()
        hold.yield()
        await model.cancelForQuit()
        #expect(!model.isRunning)
        #expect(model.remainingCount == 0)
        #expect(model.quitDecision == .quitNow)
    }
}
