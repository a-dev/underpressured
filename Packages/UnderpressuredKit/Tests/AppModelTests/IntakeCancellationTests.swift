import UnderpressuredApplication
import Foundation
import Synchronization
import Testing
@testable import AppModel
import UnderpressuredCore

/// Holds one scan at a bounded synchronous gate, so cancellation can be tested
/// while the scanner is definitely still in flight.
private final class ScanHold: Sendable {
    let started = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)

    func waitUntilStarted() async {
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func releaseScan() { release.signal() }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct IntakeCancellationTests {
    @Test func cancelDuringScanReturnsIdleDiscardsLateResultAndAllowsNextDrop() async {
        let hold = ScanHold()
        let processed = Mutex(0)
        let queue = Queue(parallelism: 1) { _, _, executionContext, _ in
            processed.withLock { $0 += 1 }
            return .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: URL(filePath: "/out"))
        }
        let sleep = RecordingSleepPreventer()
        let model = AppModel(queue: queue, intake: { urls, _, _ in
            if urls[0].lastPathComponent == "held.jpg" {
                hold.started.continuation.yield(())
                #expect(hold.release.wait(timeout: .now() + 5) == .success)
                return ScanResult(failures: [ScanFailure(url: urls[0], reason: .noPermission)])
            }
            return ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) })
        }, sleepPreventer: sleep, updateInterval: .zero)

        let heldOpen = Task { await model.open([URL(filePath: "/held.jpg")]) }
        await hold.waitUntilStarted()
        let waitingOpen = Task { await model.open([URL(filePath: "/waiting.jpg")]) }
        while model.pendingScans < 2, !Task.isCancelled { await Task.yield() }
        #expect(model.pendingScans == 2)
        await model.cancel()
        #expect(!model.isRunning)
        #expect(model.pendingScans == 0)
        #expect(sleep.calls == [true, false])

        #expect(processed.withLock { $0 } == 0)
        #expect((await queue.snapshot).isEmpty)

        // A new generation must run even while the old filesystem call is blocked.
        await model.open([URL(filePath: "/fresh.jpg")])
        await model.untilIdle()
        #expect(model.rows.map(\.name) == ["fresh.jpg"])
        #expect(processed.withLock { $0 } == 1)
        hold.releaseScan()
        await heldOpen.value
        await waitingOpen.value
        await model.untilIdle()

        #expect(model.rows.map(\.name) == ["fresh.jpg"])
        #expect(model.intakeFailures.isEmpty)
        #expect(processed.withLock { $0 } == 1)
    }

    @Test func cancelForQuitDuringScanUsesScanOnlyPromptAndReturnsIdle() async {
        let hold = ScanHold()
        let processed = Mutex(0)
        let queue = Queue(parallelism: 1) { _, _, executionContext, _ in
            processed.withLock { $0 += 1 }
            return .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: URL(filePath: "/out"))
        }
        let sleep = RecordingSleepPreventer()
        let model = AppModel(queue: queue, intake: { urls, _, _ in
            hold.started.continuation.yield(())
            #expect(hold.release.wait(timeout: .now() + 5) == .success)
            return ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) })
        }, sleepPreventer: sleep, updateInterval: .zero)

        let heldOpen = Task { await model.open([URL(filePath: "/held.jpg")]) }
        await hold.waitUntilStarted()
        #expect(model.quitDecision == .confirm(message: "Cancel scanning and any remaining images and quit?"))

        let quitting = Task { await model.cancelForQuit() }
        await quitting.value
        #expect(!model.isRunning)
        #expect(model.pendingScans == 0)
        #expect(sleep.calls == [true, false])

        hold.releaseScan()
        await heldOpen.value
        #expect(model.rows.isEmpty)
        #expect(processed.withLock { $0 } == 0)
    }
}
