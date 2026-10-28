import Foundation
import Testing
@testable import UnderpressuredCore
@testable import UnderpressuredApplication
import QueueTestSupport

/// Real Queue + Pipeline: each input has distinct bytes so aliasing cannot hide behind success counts.
struct RunReservationTests {
    let files = InMemoryFileAccess()
    let codec = FakeCodec()
    let settings = EffectiveSettings(quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)
    let export = URL(filePath: "/Export")

    private func batch(_ source: String, byte: UInt8, quality: Quality = 80, root: String? = nil) -> Batch {
        let url = URL(filePath: source)
        let data = Data(repeating: byte, count: 1000)
        files.addFile(url, data: data)
        codec.setEncode(.success(EncodedImage(
            data: Data(repeating: byte, count: 500), format: .jpeg, pixelWidth: 100, pixelHeight: 100)), for: data)
        return Batch(settings: EffectiveSettings(quality: quality, lossless: false, resizeRule: .none, keepMetadata: false), outputFormat: .original, destination: .exportFolder(export),
                     items: [Item(source: url, droppedRoot: root.map { URL(filePath: $0) })])
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func overlappingDrops_preserveBytesAndRowURLs(firstCommitted: Bool) async throws {
        files.addDirectory(export)
        let first = batch("/one/a.jpg", byte: 1)
        // Keeps the run active after the first commits, without relying on timing.
        let blocker = batch("/hold/block.jpg", byte: 3)
        let second = batch("/two/a.jpg", byte: 2, quality: 50)
        let pipeline = Pipeline(fileAccess: files, codec: codec)
        codec.hold(.encode)
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            codec.release(.encode)
            codec.release(.inspect)
        }
        defer { watchdog.cancel(); codec.release(.encode) }
        let queue = Queue(parallelism: firstCommitted ? 1 : 3, pipeline: pipeline.itemPipeline)
        var events = queue.events.makeAsyncIterator()
        var history = QueueEventHistory()
        await queue.enqueue(first)
        await queue.enqueue(blocker)
        if firstCommitted {
            // The second item is held at inspection while the first can complete.
            await codec.waitUntilStarted(.encode)
            codec.hold(.inspect)
            codec.release(.encode)
            while let event = await events.next() {
                history.apply(event)
                if case .itemChanged(let id, _, .finished) = event, id == first.id { break }
            }
        } else {
            await codec.waitUntilStarted(.encode, count: 2)
        }
        await queue.enqueue(second)
        if !firstCommitted { await codec.waitUntilStarted(.encode, count: 3) }
        codec.release(.inspect)
        codec.release(.encode)
        while let event = await events.next() {
            history.apply(event)
            if event == .idle { break }
        }
        let batches = history.batches
        let a = URL(filePath: "/Export/a.jpg")
        let b = URL(filePath: "/Export/a-2.jpg")
        #expect(batches[0].items[0].state == .finished(.optimized(
            Savings(originalBytes: 1000, newBytes: 500), notes: [], output: a)))
        #expect(batches[2].items[0].state == .finished(.optimized(
            Savings(originalBytes: 1000, newBytes: 500), notes: [], output: b)))
        #expect(files.data(at: a) == Data(repeating: 1, count: 500))
        #expect(files.data(at: b) == Data(repeating: 2, count: 500))
        #expect(codec.calls.contains(.encode(Data(repeating: 1, count: 1000),
            EncodePlan(format: .jpeg, quality: 80, lossless: false, keepMetadata: false))))
        #expect(codec.calls.contains(.encode(Data(repeating: 2, count: 1000),
            EncodePlan(format: .jpeg, quality: 50, lossless: false, keepMetadata: false))))
        #expect((await queue.diagnostics).reservedPaths == 0)

        let later = batch("/later/a.jpg", byte: 4)
        await queue.enqueue(later)
        while let event = await events.next() {
            history.apply(event)
            if event == .idle { break }
        }
        let refreshed = try #require(history.batches.last)
        #expect(refreshed.items[0].state == .finished(.optimized(
            Savings(originalBytes: 1000, newBytes: 500), notes: [], output: a)))
        #expect(files.data(at: a) == Data(repeating: 4, count: 500))
        #expect(files.data(at: b) == Data(repeating: 2, count: 500))
    }

    @Test(arguments: [false, true])
    func sameNameRootsAndCaseAliases_shareReservations(caseSensitive: Bool) async {
        files.setCaseSensitive(caseSensitive)
        files.addDirectory(export)
        let first = batch("/one/Trip/a.jpg", byte: 1, root: "/one/Trip")
        let second = batch("/two/Trip/A.jpg", byte: 2, root: "/two/Trip")
        let context = QueueExecutionContext()
        let pipeline = Pipeline(fileAccess: files, codec: codec)
        let gate = StageGate { _ throws(CancellationError) in }
        let a = URL(filePath: "/Export/Trip/a.jpg")
        let b = URL(filePath: caseSensitive ? "/Export/Trip/A.jpg" : "/Export/Trip/A-2.jpg")
        #expect(await pipeline.run(first.items[0], in: first.context, executionContext: context, gate: gate) == .optimized(
            Savings(originalBytes: 1000, newBytes: 500), notes: [], output: a))
        #expect(await pipeline.run(second.items[0], in: second.context, executionContext: context, gate: gate) == .optimized(
            Savings(originalBytes: 1000, newBytes: 500), notes: [], output: b))
        #expect(files.data(at: a) == Data(repeating: 1, count: 500))
        #expect(files.data(at: b) == Data(repeating: 2, count: 500))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledQueue_retiresContextOnlyAfterPipelineReturns() async throws {
        files.addDirectory(export)
        let first = batch("/one/a.jpg", byte: 1)
        let second = batch("/two/a.jpg", byte: 2)
        let pipeline = Pipeline(fileAccess: files, codec: codec)
        let queue = Queue(parallelism: 1, pipeline: pipeline.itemPipeline)
        var events = queue.events.makeAsyncIterator()
        var history = QueueEventHistory()
        codec.hold(.encode)
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            codec.release(.encode)
        }
        defer { watchdog.cancel(); codec.release(.encode) }
        await queue.enqueue(first)
        await codec.waitUntilStarted(.encode)
        await queue.cancel()
        #expect((await queue.diagnostics).reservedPaths == 1)
        codec.release(.encode)
        while let event = await events.next() {
            history.apply(event)
            if event == .idle { break }
        }
        #expect((await queue.diagnostics).reservedPaths == 0)
        #expect(history.batches.first?.items.first?.state == .finished(.cancelled))
        #expect(files.data(at: URL(filePath: "/Export/a.jpg")) == nil)
        await queue.enqueue(second)
        while let event = await events.next() {
            history.apply(event)
            if event == .idle { break }
        }
        let output = URL(filePath: "/Export/a.jpg")
        #expect(history.batches.last?.items.first?.state == .finished(.optimized(
            Savings(originalBytes: 1000, newBytes: 500), notes: [], output: output)))
        #expect(files.data(at: output) == Data(repeating: 2, count: 500))
    }

    @Test func cancelledClaim_isKeptUntilRunDrains() async {
        files.addDirectory(export)
        let first = batch("/one/a.jpg", byte: 1)
        let second = batch("/two/a.jpg", byte: 2)
        let context = QueueExecutionContext()
        let pipeline = Pipeline(fileAccess: files, codec: codec)
        let cancelled = StageGate { stage throws(CancellationError) in
            if stage == .encoding { throw CancellationError() }
        }
        #expect(await pipeline.run(first.items[0], in: first.context, executionContext: context, gate: cancelled) == .cancelled)
        let b = URL(filePath: "/Export/a-2.jpg")
        #expect(await pipeline.run(second.items[0], in: second.context, executionContext: context,
                                   gate: StageGate { _ throws(CancellationError) in }) == .optimized(
            Savings(originalBytes: 1000, newBytes: 500), notes: [], output: b))
        #expect(files.data(at: URL(filePath: "/Export/a.jpg")) == nil)
        #expect(files.data(at: b) == Data(repeating: 2, count: 500))
    }
}
