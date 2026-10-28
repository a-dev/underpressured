import Foundation
import Synchronization
import Testing
import QueueTestSupport

@testable import UnderpressuredCore
@testable import UnderpressuredApplication

/// The pixel budget (§7.7). Each Item's name is its pixel count ("60.jpg" = 60 pixels). Items hold
/// after admission until the test lets them go, so every wait is on a gate, never on time.
@Suite(.timeLimit(.minutes(1)))
struct PixelBudgetTests {
    /// Admission order and the pixels held by admitted, unfinished Items.
    final class Admissions: Sendable {
        private struct State {
            var order: [String] = []
            var inFlight = 0
            var peak = 0
            var released: Set<String> = []
            var holds: [String: CheckedContinuation<Void, Never>] = [:]
            var admitWaiters: [(String, CheckedContinuation<Void, Never>)] = []
        }
        private let state = Mutex(State())

        var order: [String] { state.withLock { $0.order } }
        var peak: Int { state.withLock { $0.peak } }

        /// Called by the pipeline after its reservation; returns once the test releases `name`.
        func admitted(_ name: String, pixels: Int) async {
            await withCheckedContinuation { (hold: CheckedContinuation<Void, Never>) in
                let wake = state.withLock { (s: inout State) -> [CheckedContinuation<Void, Never>] in
                    s.order.append(name)
                    s.inFlight += pixels
                    s.peak = max(s.peak, s.inFlight)
                    if s.released.contains(name) { hold.resume() } else { s.holds[name] = hold }
                    let ready = s.admitWaiters.filter { $0.0 == name }.map(\.1)
                    s.admitWaiters.removeAll { $0.0 == name }
                    return ready
                }
                wake.forEach { $0.resume() }
            }
            state.withLock { $0.inFlight -= pixels }
        }

        func release(_ name: String) {
            let hold = state.withLock { (s: inout State) in
                s.released.insert(name)
                return s.holds.removeValue(forKey: name)
            }
            hold?.resume()
        }

        func waitUntilAdmitted(_ name: String) async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let already = state.withLock { (s: inout State) -> Bool in
                    if s.order.contains(name) { return true }
                    s.admitWaiters.append((name, c))
                    return false
                }
                if already { c.resume() }
            }
        }
    }

    let admissions = Admissions()

    private func makeQueue(budget: Int, parallelism: Int = 8) -> Queue {
        let admissions = admissions
        return Queue(parallelism: parallelism, pixelBudget: budget) { item, _, executionContext, gate in
            let name = item.source.deletingPathExtension().lastPathComponent
            let pixels = Int(name.prefix { $0.isNumber })!
            do {
                try await gate.enter(.decoding)
                try await gate.reservePixels(pixels)
            } catch {
                return .cancelled
            }
            await admissions.admitted(name, pixels: min(pixels, 100))
            return .skipped(.alreadyOptimal, notes: [])
        }
    }

    private func batch(_ names: String...) -> Batch {
        Batch(
            settings: EffectiveSettings(quality: 80, lossless: false, resizeRule: .none, keepMetadata: false),
            outputFormat: .original, destination: .exportFolder(URL(filePath: "/Export")),
            items: names.map { Item(source: URL(filePath: "/in/\($0).jpg"), droppedRoot: nil) })
    }

    /// Every Item not yet admitted has asked for its pixels and is waiting.
    private func untilWaiting(_ queue: Queue, _ count: Int) async {
        while await queue.pixelWaiterCount < count { await Task.yield() }
    }

    @discardableResult
    private func untilIdle(_ queue: Queue) async -> QueueEventHistory {
        var events = queue.events.makeAsyncIterator()
        var history = QueueEventHistory()
        while let event = await events.next() {
            history.apply(event)
            if event == .idle { break }
        }
        return history
    }

    /// Adds one Item at a time, each as its own Batch, waiting until it is admitted or waiting
    /// for pixels before the next, so the order Items ask for pixels is the order given.
    private func enqueueInOrder(_ queue: Queue, _ names: String...) async {
        for name in names {
            let before = await queue.pixelWaiterCount
            await queue.enqueue(batch(name))
            while !admissions.order.contains(name), await queue.pixelWaiterCount == before {
                await Task.yield()
            }
        }
    }

    @Test func pixelsInFlightStayWithinBudget_spec7_7() async {
        let queue = makeQueue(budget: 100)
        await enqueueInOrder(queue, "40a", "40b", "40c", "40d")
        #expect(admissions.order == ["40a", "40b"], "a third 40 would exceed 100")
        #expect(await queue.pixelWaiterCount == 2)
        #expect(await queue.pixelsInFlight == 80)

        admissions.release("40a")
        await admissions.waitUntilAdmitted("40c")
        admissions.release("40b")
        await admissions.waitUntilAdmitted("40d")
        admissions.release("40c")
        admissions.release("40d")
        await untilIdle(queue)

        #expect(admissions.peak <= 100)
        #expect(await queue.pixelsInFlight == 0)
    }

    @Test func imageOverBudgetRunsAlone_spec7_7() async {
        let queue = makeQueue(budget: 100)
        await enqueueInOrder(queue, "10a", "500", "10b")
        #expect(admissions.order == ["10a"], "the huge image waits for the budget to empty")

        admissions.release("10a")
        await admissions.waitUntilAdmitted("500")
        await untilWaiting(queue, 1)
        #expect(admissions.order == ["10a", "500"], "nothing runs beside it")
        #expect(await queue.pixelsInFlight == 100)

        admissions.release("500")
        await admissions.waitUntilAdmitted("10b")
        admissions.release("10b")
        await untilIdle(queue)
        #expect(admissions.order == ["10a", "500", "10b"])
    }

    @Test func smallImagesDoNotOvertakeAWaitingLargeOne_spec7_7() async {
        let queue = makeQueue(budget: 100)
        await enqueueInOrder(queue, "60", "80", "10a", "10b")
        // 10a and 10b would fit beside 60, but 80 is first in line.
        #expect(admissions.order == ["60"])
        #expect(await queue.pixelWaiterCount == 3)

        admissions.release("60")
        for name in ["80", "10a", "10b"] { await admissions.waitUntilAdmitted(name) }
        #expect(await queue.pixelsInFlight == 100)
        for name in ["80", "10a", "10b"] { admissions.release(name) }
        await untilIdle(queue)
    }

    @Test func cancelStopsItemsWaitingForPixels_spec7_6() async {
        let queue = makeQueue(budget: 100)
        await enqueueInOrder(queue, "100", "50")
        await queue.cancel()
        admissions.release("100")
        let history = await untilIdle(queue)
        let states = history.batches.flatMap { $0.items.map(\.state) }
        #expect(states == [.finished(.cancelled), .finished(.cancelled)])
        #expect(admissions.order == ["100"])
        #expect(await queue.pixelsInFlight == 0)
    }
}
