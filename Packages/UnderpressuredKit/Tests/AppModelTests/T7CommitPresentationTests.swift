import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore
@testable import UnderpressuredApplication

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct T7CommitPresentationTests {
    @Test func cancellationAfterCommitKeepsOutputAndCompletionTotals() async {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let output = URL(filePath: "/out/finished.jpg")
        let queue = Queue(parallelism: 1, pixelBudget: 1_000_000) { _, _, executionContext, gate in
            do { try await gate.enter(.writing) } catch { return .cancelled }
            gate.committed()
            started.continuation.yield()
            for await _ in release.stream { break }
            return .optimized(Savings(originalBytes: 1_000, newBytes: 400), notes: [], output: output)
        }
        let model = AppModel(
            queue: queue,
            intake: { urls, _, _ in
                ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: 0)
            })

        await model.open([URL(filePath: "/tmp/source.jpg")])
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        await model.cancel()
        release.continuation.yield()
        release.continuation.finish()
        await model.untilIdle()

        #expect(model.rows.count == 1)
        #expect(model.rows[0].stateText == "Optimized")
        #expect(model.rows[0].openURL == output)
        #expect(model.banner?.text == "1 image · 600 bytes saved (60%)")
        #expect(model.banner?.filters.isEmpty == true)
    }
}
