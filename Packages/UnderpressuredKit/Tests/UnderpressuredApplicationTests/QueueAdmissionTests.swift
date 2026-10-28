import Foundation
import Testing

import QueueTestSupport
@testable import UnderpressuredCore
@testable import UnderpressuredApplication

@Suite(.timeLimit(.minutes(1)))
struct QueueAdmissionTests {
    let codec = FakeCodec()

    private func queue(parallelism: Int = 1) -> Queue {
        let codec = codec
        return Queue(parallelism: parallelism, pixelBudget: 1_000_000) { item, _, executionContext, _ in
            let data = Data(item.source.path.utf8)
            do {
                let image = try await codec.decode(data)
                let encoded = try await codec.encode(
                    image, EncodePlan(format: .jpeg, quality: 80, lossless: false, keepMetadata: false))
                return .optimized(
                    Savings(originalBytes: Int64(data.count), newBytes: Int64(encoded.data.count)),
                    notes: [], output: item.source)
            } catch {
                return .failed(.encodeFailed)
            }
        }
    }

    private func batch(_ items: [Item]) -> Batch {
        Batch(settings: EffectiveSettings(quality: 80, lossless: false, resizeRule: .none, keepMetadata: false),
              outputFormat: .original, destination: .exportFolder(URL(filePath: "/Export")), items: items)
    }

    private func item(
        _ path: String, id: UUID = UUID(), attributes: FileAttributes? = nil,
        caseSensitive: Bool = true
    ) -> Item {
        let source = URL(filePath: path)
        return Item(
            id: id, source: source, droppedRoot: nil, sourceAttributes: attributes,
            sourceCaseSensitive: caseSensitive)
    }

    private func active(_ state: ItemState) -> Bool {
        switch state {
        case .waiting, .processing: true
        case .finished: false
        }
    }

    @Test func cancelledRequestCannotEnterQueue() async {
        let queue = queue()
        let batch = batch([item("/in/cancelled.jpg")])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await queue.enqueue(batch)
        }
        #expect(await task.value == false)
        #expect(await queue.snapshot.isEmpty)
    }

    @Test func concurrentAdmissionsOfOneIdentity_onlyOneRuns() async {
        let queue = queue()
        let history = QueueEventRecorder.observe(queue.events)
        codec.hold(.decode)
        let first = item("/in/photo.jpg")
        await queue.enqueue(batch([first]))
        await history.waitForBatchCount(1)
        await codec.waitUntilStarted(.decode)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask { await queue.enqueue(self.batch([self.item("/in/./photo.jpg")])) }
            }
        }
        await history.waitForBatchCount(25)
        let rows = await history.batches.flatMap(\.items)
        #expect(rows.filter { active($0.state) }.count == 1)
        #expect(rows.filter { $0.state == .finished(.skipped(.alreadyInQueue, notes: [])) }.count == 24)
        #expect(codec.calls.filter { $0.operation == .decode }.count == 1)

        codec.release(.decode)
        await history.waitUntilIdle()
        #expect(codec.calls.filter { $0.operation == .decode }.count == 1)
    }

    @Test func normalizedPathsMatchButCaseSensitivePathsDoNot() async {
        let queue = queue(parallelism: 4)
        let history = QueueEventRecorder.observe(queue.events)
        codec.hold(.decode)
        await queue.enqueue(batch([item("/in/folder/../photo.jpg")] ))
        await codec.waitUntilStarted(.decode)
        await queue.enqueue(batch([item("/in/photo.jpg")] ))
        await queue.enqueue(batch([
            item("/in/Photo.jpg", attributes: nil, caseSensitive: true)
        ]))
        await history.waitForBatchCount(3)
        await codec.waitUntilStarted(.decode, count: 2)

        let rows = await history.batches.flatMap(\.items)
        #expect(rows[1].state == .finished(.skipped(.alreadyInQueue, notes: [])))
        #expect(active(rows[2].state))
        #expect(codec.calls.filter { $0.operation == .decode }.count == 2)
        codec.release(.decode)
        await history.waitUntilIdle()
    }

    @Test func caseInsensitiveAliasesAndHardLinksMatch() async {
        let queue = queue(parallelism: 2)
        let history = QueueEventRecorder.observe(queue.events)
        codec.hold(.decode)
        await queue.enqueue(batch([item("/in/Photo.jpg", caseSensitive: false)]))
        await codec.waitUntilStarted(.decode)
        await queue.enqueue(batch([item("/in/photo.jpg", caseSensitive: false)]))
        let sharedFile = FileAttributes(kind: .file, fileIdentity: 91, volumeIdentity: 7)
        await queue.enqueue(batch([item("/in/other-name.jpg", attributes: sharedFile)]))
        await queue.enqueue(batch([item("/in/hard-link.jpg", attributes: sharedFile)]))
        await history.waitForBatchCount(4)
        await codec.waitUntilStarted(.decode, count: 2)

        let rows = await history.batches.flatMap(\.items)
        #expect(rows[1].state == .finished(.skipped(.alreadyInQueue, notes: [])))
        #expect(active(rows[2].state))
        #expect(rows[3].state == .finished(.skipped(.alreadyInQueue, notes: [])))
        #expect(codec.calls.filter { $0.operation == .decode }.count == 2)
        codec.release(.decode)
        await history.waitUntilIdle()
    }

    @Test func identityCanBeReadmittedAfterFinish_andStaleScanOnlySkipsIfActive() async {
        let queue = queue()
        let history = QueueEventRecorder.observe(queue.events)
        let path = "/in/photo.jpg"
        codec.hold(.decode)
        await queue.enqueue(batch([item(path)]))
        await history.waitForBatchCount(1)
        await codec.waitUntilStarted(.decode)

        var staleWhileActive = item(path)
        staleWhileActive.state = .finished(.skipped(.alreadyInQueue, notes: []))
        await queue.enqueue(batch([staleWhileActive]))
        await history.waitForBatchCount(2)
        #expect(await history.batches.last?.items.first?.state == .finished(.skipped(.alreadyInQueue, notes: [])))
        #expect(codec.calls.filter { $0.operation == .decode }.count == 1)

        codec.release(.decode)
        await history.waitUntilIdle()
        #expect(await history.batches.first?.items.first?.state.isFinished == true)

        var staleAfterFinish = item(path)
        staleAfterFinish.state = .finished(.skipped(.alreadyInQueue, notes: []))
        codec.hold(.decode)
        await queue.enqueue(batch([staleAfterFinish]))
        await history.waitForBatchCount(3)
        #expect(await history.batches.last?.items.first.map { active($0.state) } == true)
        codec.release(.decode)
        await history.waitUntilIdle()
        #expect(await history.batches.last?.items.first?.state.isFinished == true)
        #expect(codec.calls.filter { $0.operation == .decode }.count == 2)
    }

    @Test func duplicateItemIDsWithinBatchAreRejectedWithoutSideEffects() async {
        let duplicateID = UUID()
        await expectRejectedAdmissionAndRetry(
            rejectedBatch: batch([
                item("/in/rejected-a.jpg", id: duplicateID),
                item("/in/rejected-b.jpg", id: duplicateID)
            ]),
            retryPath: "/in/rejected-a.jpg")
    }

    @Test func activeBatchIDCollisionIsRejectedWithoutSideEffects() async {
        let activeBatchID = UUID()
        let collidingBatch = Batch(
            id: activeBatchID, settings: settings, outputFormat: .original,
            destination: .exportFolder(URL(filePath: "/Export")),
            items: [item("/in/rejected.jpg")])
        await expectRejectedAdmissionAndRetry(
            activeBatchID: activeBatchID, rejectedBatch: collidingBatch,
            retryPath: "/in/rejected.jpg")
    }

    @Test func activeItemIDCollisionWithDifferentSourceIsRejectedWithoutSideEffects() async {
        let activeItemID = UUID()
        await expectRejectedAdmissionAndRetry(
            activeItemID: activeItemID,
            rejectedBatch: batch([item("/in/rejected.jpg", id: activeItemID)]),
            retryPath: "/in/rejected.jpg")
    }

    private var settings: EffectiveSettings {
        EffectiveSettings(quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)
    }

    private func expectRejectedAdmissionAndRetry(
        activeBatchID: UUID = UUID(), activeItemID: UUID = UUID(),
        rejectedBatch: Batch, retryPath: String
    ) async {
        let queue = queue()
        let history = QueueEventRecorder.observe(queue.events)
        codec.hold(.decode)
        defer { codec.release(.decode) }
        let activeItem = item("/in/held.jpg", id: activeItemID)
        let activeBatch = Batch(
            id: activeBatchID, settings: settings, outputFormat: .original,
            destination: .exportFolder(URL(filePath: "/Export")), items: [activeItem])
        #expect(await queue.enqueue(activeBatch))
        await history.waitForBatchCount(1)
        await codec.waitUntilStarted(.decode)

        let before = await queue.diagnostics
        #expect(await queue.enqueue(rejectedBatch) == false)
        #expect(await queue.isActive(URL(filePath: retryPath)) == false)
        let after = await queue.diagnostics
        #expect(after.items == before.items)
        #expect(after.batches == before.batches)
        #expect(after.waitingSlots == before.waitingSlots)
        #expect(after.pixelWaiterSlots == before.pixelWaiterSlots)
        #expect(after.activeSources == before.activeSources)
        #expect(after.reservedPaths == before.reservedPaths)
        #expect(after.cachedBatches == before.cachedBatches)
        #expect(after.hasExecutionContext == before.hasExecutionContext)
        #expect(after.work.admissions == before.work.admissions)
        #expect(after.work.waitingVisits == before.work.waitingVisits)
        #expect(after.work.stateLookups == before.work.stateLookups)
        #expect(after.work.finishes == before.work.finishes)
        #expect(after.work.pixelWaiterVisits == before.work.pixelWaiterVisits)

        codec.release(.decode)
        await history.waitUntilIdle()
        #expect(codec.count(.decode) == 1)
        #expect(await queue.diagnostics.work.finishes == 1)
        #expect(await history.batches.count == 1)
        #expect(await history.batches[0].items.map(\.id) == [activeItemID])
        #expect(await history.batches[0].items[0].state.isFinished)

        // The rejected source was never reserved. Retrying it after the active work drains succeeds.
        #expect(await queue.enqueue(batch([item(retryPath)])))
        await history.waitForBatchCount(2)
        await history.waitUntilIdle()
        #expect(await history.batches.count == 2)
        #expect(codec.count(.decode) == 2)
        #expect(await queue.diagnostics.work.finishes == 2)
        #expect(await history.batches[1].items[0].source == URL(filePath: retryPath))
    }
}
