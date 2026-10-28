import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

@MainActor
final class RecordingSleepPreventer: SleepPreventer {
    private(set) var calls: [Bool] = []
    func setPreventing(_ preventing: Bool, reason: String) { calls.append(preventing) }
}

/// A model whose single worker holds the first Item in Processing until `release()`.
@MainActor
struct HeldModel {
    let model: AppModel
    let sleep = RecordingSleepPreventer()
    private let hold: AsyncStream<Void>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        hold = continuation
        let queue = Queue(parallelism: 1, pixelBudget: 1_000_000) { _, _, executionContext, gate in
            try? await gate.enter(.decoding)
            for await _ in stream { break }
            return .optimized(Savings(originalBytes: 1_000, newBytes: 400), notes: [], output: URL(filePath: "/out"))
        }
        model = AppModel(
            queue: queue,
            intake: { urls, _, _ in ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: 0) },
            sleepPreventer: sleep)
    }

    func release() { for _ in 0..<10 { hold.yield() } }

    /// Drops `count` images and waits until the first one is Processing.
    func start(_ count: Int) async {
        await model.open((0..<count).map { URL(filePath: "/tmp/\($0).jpg") })
        while !model.rows.contains(where: { $0.stateText != "Waiting" }) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

@MainActor
@Suite struct QuitTests {
    @Test func idleQuitsNow() {
        #expect(makeModel().quitDecision == .quitNow)
    }

    @Test func runningAsksWithTheRemainingCount() async {
        let held = HeldModel()
        await held.start(3)
        #expect(held.model.quitDecision == .confirm(message: "Cancel 3 remaining images and quit?"))
        held.release()
        await held.model.untilIdle()
    }

    @Test func oneRemainingImageIsSingular() async {
        let held = HeldModel()
        await held.start(1)
        #expect(held.model.quitDecision == .confirm(message: "Cancel 1 remaining image and quit?"))
        held.release()
        await held.model.untilIdle()
    }

    @Test func cancelForQuitFinishesEverythingAsCancelled() async {
        let held = HeldModel()
        await held.start(3)
        let quitting = Task { await held.model.cancelForQuit() }
        try? await Task.sleep(for: .milliseconds(50))
        held.release()
        await quitting.value

        #expect(!held.model.isRunning)
        #expect(held.model.rows.count == 3)
        #expect(held.model.rows.allSatisfy { $0.stateText == "Cancelled" })
        #expect(held.model.quitDecision == .quitNow)
    }

    @Test func sleepIsPreventedOnlyWhileRunning() async {
        let held = HeldModel()
        await held.start(1)
        #expect(held.sleep.calls == [true])
        held.release()
        await held.model.untilIdle()
        #expect(held.sleep.calls == [true, false])
    }
}
