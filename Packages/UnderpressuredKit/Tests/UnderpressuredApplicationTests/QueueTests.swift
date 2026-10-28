import Foundation
import Testing

import QueueTestSupport
@testable import UnderpressuredCore
@testable import UnderpressuredApplication

/// Every wait is on a FakeCodec gate or on a Queue event, never on time.
@Suite(.timeLimit(.minutes(1)))
struct QueueTests {
    let codec = FakeCodec()

    /// A two-stage pipeline: decoding and encoding, with a gate before each.
    private func makeQueue(parallelism: Int = 1) -> Queue {
        let codec = codec
        return Queue(parallelism: parallelism, pixelBudget: 1_000_000) { item, batch, executionContext, gate in
            let data = Data(item.source.path.utf8)
            do {
                try await gate.enter(.decoding)
                let image = try await codec.decode(data)
                try await gate.enter(.encoding)
                let encoded = try await codec.encode(
                    image, EncodePlan(format: .jpeg, quality: 80, lossless: false, keepMetadata: false))
                return .optimized(
                    Savings(originalBytes: Int64(data.count), newBytes: Int64(encoded.data.count)), notes: [],
                    output: item.source)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(.encodeFailed)
            }
        }
    }

    private func batch(_ names: String...) -> Batch {
        Batch(
            settings: EffectiveSettings(quality: 80, lossless: false, resizeRule: .none, keepMetadata: false),
            outputFormat: .original, destination: .exportFolder(URL(filePath: "/Export")),
            items: names.map { Item(source: URL(filePath: "/in/\($0)"), droppedRoot: nil) })
    }

    private func states(_ queue: Queue) async -> [ItemState] {
        await queue.snapshot.flatMap { $0.items.map(\.state) }
    }

    private func states(_ history: QueueEventHistory) -> [ItemState] {
        history.batches.flatMap { $0.items.map(\.state) }
    }

    private func untilIdle(_ events: inout AsyncStream<QueueEvent>.Iterator) async -> [QueueEvent] {
        var seen: [QueueEvent] = []
        while let event = await events.next() {
            seen.append(event)
            if event == .idle { break }
        }
        return seen
    }

    private func isOptimized(_ state: ItemState) -> Bool {
        if case .finished(.optimized) = state { true } else { false }
    }

    @Test func publishedRowsAreIndependentOfQueueExecution() async throws {
        let queue = makeQueue()
        codec.hold(.decode)
        defer { codec.release(.decode) }
        var events = queue.events.makeAsyncIterator()
        let input = batch("a.jpg", "b.jpg")
        await queue.enqueue(input)
        await codec.waitUntilStarted(.decode)
        guard case .batchAdded(var published) = await events.next() else {
            Issue.record("Expected the immutable admission snapshot")
            return
        }
        published.items[0].state = .finished(.cancelled)
        published.items.removeLast()
        #expect(await states(queue) == [.processing(.decoding), .waiting])
        #expect(input.items.map(\.state) == [.waiting, .waiting])
        codec.release(.decode)
        let seen = await untilIdle(&events)
        let terminals = seen.compactMap { event -> Item.ID? in
            if case .itemChanged(_, let id, .finished) = event { return id }
            return nil
        }
        #expect(Set(terminals) == Set(input.items.map(\.id)))
        #expect(terminals.count == 2)
    }

    @Test func itemGoesWaitingProcessingOutcome_spec7_1() async {
        let queue = makeQueue()
        var events = queue.events.makeAsyncIterator()
        codec.hold(.decode)
        await queue.enqueue(batch("a.jpg", "b.jpg"))
        await codec.waitUntilStarted(.decode)
        #expect(await states(queue) == [.processing(.decoding), .waiting])

        codec.release(.decode)
        let seen = await untilIdle(&events)
        var history = QueueEventHistory()
        history.apply(seen)
        #expect(states(history).count == 2)
        #expect(states(history).allSatisfy(isOptimized))
    }

    @Test func eventsReportEveryTransition_spec7_1() async throws {
        let queue = makeQueue()
        var events = queue.events.makeAsyncIterator()
        let b = batch("a.jpg")
        await queue.enqueue(b)
        let seen = await untilIdle(&events)

        #expect(seen.first == .batchAdded(b))
        let itemStates = seen.compactMap { event -> ItemState? in
            if case .itemChanged(_, _, let state) = event { state } else { nil }
        }
        #expect(itemStates.dropLast() == [.processing(.checkingMark), .processing(.decoding), .processing(.encoding)])
        #expect(isOptimized(try #require(itemStates.last)))
        #expect(seen.last == .idle)
    }

    @Test func batchesRunInDropOrder_spec7_1() async {
        let queue = makeQueue()
        var events = queue.events.makeAsyncIterator()
        codec.hold(.decode)
        await queue.enqueue(batch("1.jpg", "2.jpg"))
        await queue.enqueue(batch("3.jpg"))
        codec.release(.decode)
        _ = await untilIdle(&events)

        let decoded = codec.calls.filter { $0.operation == .decode }.map { String(decoding: $0.input, as: UTF8.self) }
        #expect(decoded == ["/in/1.jpg", "/in/2.jpg", "/in/3.jpg"])
    }

    @Test func dropWhileRunningAppendsBatch_spec7_1() async {
        let queue = makeQueue()
        var events = queue.events.makeAsyncIterator()
        codec.hold(.decode)
        let first = batch("a.jpg")
        let second = batch("b.jpg")
        await queue.enqueue(first)
        await codec.waitUntilStarted(.decode)
        await queue.enqueue(second)
        #expect(await queue.snapshot.map(\.id) == [first.id, second.id])
        #expect(await states(queue) == [.processing(.decoding), .waiting])

        codec.release(.decode)
        let seen = await untilIdle(&events)
        var history = QueueEventHistory()
        history.apply(seen)
        #expect(states(history).count == 2)
        #expect(states(history).allSatisfy(isOptimized))
    }

    @Test func parallelismRunsItemsTogether_spec7_7() async {
        let queue = makeQueue(parallelism: 2)
        var events = queue.events.makeAsyncIterator()
        codec.hold(.decode)
        await queue.enqueue(batch("a.jpg", "b.jpg", "c.jpg"))
        await codec.waitUntilStarted(.decode, count: 2)
        #expect(await states(queue) == [.processing(.decoding), .processing(.decoding), .waiting])
        codec.release(.decode)
        _ = await untilIdle(&events)
    }

    @Test func cancelTurnsWaitingIntoCancelledAtOnce_spec7_6() async {
        let queue = makeQueue()
        var events = queue.events.makeAsyncIterator()
        codec.hold(.decode)
        await queue.enqueue(batch("a.jpg", "b.jpg"))
        await codec.waitUntilStarted(.decode)
        await queue.cancel()
        #expect(await states(queue) == [.processing(.decoding)])

        codec.release(.decode)
        let seen = await untilIdle(&events)
        var history = QueueEventHistory()
        history.apply(seen)
        #expect(states(history) == [.finished(.cancelled), .finished(.cancelled)])
    }

    @Test func cancelStopsProcessingAtNextStage_spec7_6() async {
        let queue = makeQueue()
        var events = queue.events.makeAsyncIterator()
        codec.hold(.decode)
        await queue.enqueue(batch("a.jpg"))
        await codec.waitUntilStarted(.decode)
        await queue.cancel()
        codec.release(.decode)
        let seen = await untilIdle(&events)
        var history = QueueEventHistory()
        history.apply(seen)

        #expect(states(history) == [.finished(.cancelled)])
        #expect(codec.count(.encode) == 0, "the encoding stage never starts")
    }

    @Test func cancelDuringLastStageDiscardsResult_spec7_6() async {
        let queue = makeQueue()
        var events = queue.events.makeAsyncIterator()
        codec.hold(.encode)
        await queue.enqueue(batch("a.jpg"))
        await codec.waitUntilStarted(.encode)
        await queue.cancel()
        codec.release(.encode)
        let seen = await untilIdle(&events)

        #expect(codec.count(.encode) == 1, "the codec call in progress finishes")
        var history = QueueEventHistory()
        history.apply(seen)
        #expect(states(history) == [.finished(.cancelled)])
    }

    @Test func finishedItemsStayFinishedOnCancel_spec7_6() async {
        let queue = makeQueue()
        var events = queue.events.makeAsyncIterator()
        await queue.enqueue(batch("a.jpg"))
        let firstEvents = await untilIdle(&events)
        var history = QueueEventHistory()
        history.apply(firstEvents)

        codec.hold(.decode)
        await queue.enqueue(batch("b.jpg"))
        await codec.waitUntilStarted(.decode, count: 2)
        await queue.cancel()
        codec.release(.decode)
        history.apply(await untilIdle(&events))

        let after = states(history)
        #expect(isOptimized(after[0]))
        #expect(after[1] == .finished(.cancelled))
    }

    @Test func cancelWithNothingRunningChangesNothing_spec7_6() async {
        let queue = makeQueue()
        var events = queue.events.makeAsyncIterator()
        await queue.enqueue(batch("a.jpg"))
        var history = QueueEventHistory()
        history.apply(await untilIdle(&events))
        await queue.cancel()
        #expect(states(history).count == 1)
        #expect(states(history).allSatisfy(isOptimized))
    }

    @Test func itemsFinishedByScanAreNotProcessed_spec7_2() async {
        let queue = makeQueue()
        var events = queue.events.makeAsyncIterator()
        var b = batch("a.gif")
        b.items[0].state = .finished(.skipped(.unsupported(.gif), notes: []))
        await queue.enqueue(b)
        let seen = await untilIdle(&events)

        #expect(seen == [.batchAdded(b), .idle])
        #expect(codec.calls.isEmpty)
    }

    @Test func activeSourcesAreReportedUntilFinished_spec7_2() async {
        let queue = makeQueue()
        var events = queue.events.makeAsyncIterator()
        codec.hold(.decode)
        await queue.enqueue(batch("a.jpg", "b.jpg"))
        await codec.waitUntilStarted(.decode)
        #expect(await queue.isActive(URL(filePath: "/in/a.jpg")))
        #expect(await queue.isActive(URL(filePath: "/in/./b.jpg")), "a Waiting Item counts too")

        codec.release(.decode)
        _ = await untilIdle(&events)
        #expect(await !queue.isActive(URL(filePath: "/in/a.jpg")))
    }
}
