import Foundation
import QueueTestSupport

import Testing
@testable import UnderpressuredCore
@testable import UnderpressuredApplication

@Suite(.timeLimit(.minutes(1)))
struct ExecutionRetentionTests {
    let settings = EffectiveSettings(quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)

    private func batch(_ count: Int) -> Batch {
        Batch(settings: settings, outputFormat: .original, destination: .replaceOriginals(moveToTrash: false),
              items: (0..<count).map { Item(source: URL(filePath: "/in/\($0).jpg"), droppedRoot: nil) })
    }

    @Test(arguments: [1_000, 5_000, 10_000])
    func schedulerVisitsEachItemOnce(count: Int) async {
        let queue = Queue(parallelism: 4) { _, _, executionContext, _ in .skipped(.alreadyOptimized, notes: []) }
        var events = queue.events.makeAsyncIterator()
        await queue.enqueue(batch(count))
        var terminals = 0
        var completedIDs: Set<Item.ID> = []
        while let event = await events.next(), event != .idle {
            if case .itemChanged(_, let id, .finished) = event {
                terminals += 1
                #expect(completedIDs.insert(id).inserted)
            }
        }
        #expect(terminals == count)
        let retained = await queue.diagnostics
        #expect(retained.work.admissions == count)
        #expect(retained.work.waitingVisits == count)
        #expect(retained.work.finishes == count)
        // Admissions count accepted items; waitingVisits counts scheduler candidates;
        // finishes counts worker completions. Each must occur exactly once per item.
        // stateLookups counts setState attempts. Allow up to three per item (one
        // transition beyond processing + finished), while rejecting repeated scans.
        // This is an operation budget, independent of host speed, not a required count.
        #expect(retained.work.stateLookups <= 3 * count)
        #expect(retained.items == 0 && retained.batches == 0 && retained.waitingSlots == 0)
        #expect(retained.activeSources == 0 && !retained.hasExecutionContext)
        #expect(await queue.snapshot.isEmpty)
    }

    @Test func terminalRecordsRetireWhileOtherItemsStillRun() async throws {
        let hold = AsyncStream<Void>.makeStream()
        let queue = Queue(parallelism: 2) { item, _, executionContext, _ in
            if item.source.lastPathComponent == "1.jpg" {
                for await _ in hold.stream { break }
            }
            return .skipped(.alreadyOptimized, notes: [])
        }
        defer { hold.continuation.finish() }
        let input = batch(2)
        var events = queue.events.makeAsyncIterator()
        await queue.enqueue(input)
        while let event = await events.next() {
            if case .itemChanged(_, let id, .finished) = event, id == input.items[0].id { break }
        }
        let active = await queue.snapshot
        #expect(active.count == 1)
        #expect(active.first?.items.map(\.id) == [input.items[1].id])
        #expect((await queue.diagnostics).items == 1)
        hold.continuation.yield(())
        while let event = await events.next(), event != .idle {}
        #expect(await queue.snapshot.isEmpty)
    }

    @Test func repeatedRealPipelineRunsRetirePlannerAndExecution() async throws {
        let files = InMemoryFileAccess()
        let codec = FakeCodec()
        let export = URL(filePath: "/Export")
        files.addDirectory(export)
        let pipeline = Pipeline(fileAccess: files, codec: codec)
        let queue = Queue(parallelism: 2, pipeline: pipeline.itemPipeline)
        var events = queue.events.makeAsyncIterator()
        for cycle in 0..<20 {
            let source = URL(filePath: "/in/\(cycle).jpg")
            files.addFile(source, data: Data(repeating: UInt8(cycle), count: 1000))
            await queue.enqueue(Batch(settings: settings, outputFormat: .original, destination: .exportFolder(export),
                                      items: [Item(source: source, droppedRoot: nil)]))
            var finished = 0
            while let event = await events.next(), event != .idle {
                if case .itemChanged(_, _, .finished(let outcome)) = event {
                    finished += 1
                    #expect(outcome == .optimized(Savings(originalBytes: 1000, newBytes: 500), notes: [],
                                                  output: export.appendingPathComponent("\(cycle).jpg")))
                }
            }
            #expect(finished == 1)
            #expect(files.data(at: export.appendingPathComponent("\(cycle).jpg")) == Data(count: 500))
            let retained = await queue.diagnostics
            #expect(retained.items == 0 && retained.batches == 0 && retained.waitingSlots == 0)
            #expect(retained.pixelWaiterSlots == 0 && retained.activeSources == 0 && !retained.hasExecutionContext)
            #expect(retained.reservedPaths == 0 && retained.cachedBatches == 0)
        }
    }
}
