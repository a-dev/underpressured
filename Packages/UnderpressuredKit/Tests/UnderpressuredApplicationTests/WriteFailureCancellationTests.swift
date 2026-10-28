import Foundation
import Testing

import QueueTestSupport
@testable import UnderpressuredCore
@testable import UnderpressuredApplication

@Suite(.timeLimit(.minutes(1)))
struct WriteFailureCancellationTests {
    @Test func cancellationDoesNotHideWriteFailure() async {
        let enteredWriting = AsyncStream<Void>.makeStream()
        let releaseWrite = AsyncStream<Void>.makeStream()
        let queue = Queue(parallelism: 1, pixelBudget: 1_000_000) { _, _, executionContext, gate in
            do { try await gate.enter(.writing) } catch { return .cancelled }
            enteredWriting.continuation.yield()
            for await _ in releaseWrite.stream { break }
            return .failed(.noPermission)
        }
        let batch = Batch(
            settings: EffectiveSettings(quality: 80, lossless: false, resizeRule: .none, keepMetadata: false),
            outputFormat: .original,
            destination: .exportFolder(URL(filePath: "/Export")),
            items: [Item(source: URL(filePath: "/in/a.jpg"), droppedRoot: nil)])

        await queue.enqueue(batch)
        var started = enteredWriting.stream.makeAsyncIterator()
        _ = await started.next()
        await queue.cancel()
        releaseWrite.continuation.yield()
        releaseWrite.continuation.finish()

        let history = await QueueEventHistory.collect(untilIdle: queue.events)
        #expect(history.batches.first?.items.first?.state == .finished(.failed(.noPermission)))
    }
}
