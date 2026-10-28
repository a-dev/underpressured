import MacPlatform
import Foundation
import Synchronization
import Testing

import UnderpressuredCore
@testable import UnderpressuredApplication

/// Every wait is a yield, never wall-clock time.
struct ParallelismTests {
    @Test func usesSysctlValue_spec7_7() {
        #expect(PerformanceCores.count(sysctl: { _ in 6 }, fallback: 10) == 6)
    }

    @Test func asksForPerformanceLevelZero_spec7_7() {
        let asked = Mutex<[String]>([])
        _ = PerformanceCores.count(sysctl: { name in asked.withLock { $0.append(name) }; return 4 }, fallback: 1)
        #expect(asked.withLock { $0 } == ["hw.perflevel0.physicalcpu"])
    }

    @Test func fallsBackWhenSysctlHasNoValue_spec7_7() {
        #expect(PerformanceCores.count(sysctl: { _ in nil }, fallback: 8) == 8)
        #expect(PerformanceCores.count(sysctl: { _ in 0 }, fallback: 8) == 8)
    }

    @Test func neverBelowOne_spec7_7() {
        #expect(PerformanceCores.count(sysctl: { _ in nil }, fallback: 0) == 1)
    }

    @Test func realCountIsAtLeastOne_spec7_7() {
        #expect(PerformanceCores.count() >= 1)
    }

    @Test func queueNeverProcessesMoreItemsThanCores_spec7_7() async {
        let cores = PerformanceCores.count(sysctl: { _ in 3 })
        let current = Mutex(0)
        let peak = Mutex(0)
        let queue = Queue(parallelism: cores, pixelBudget: 1_000_000) { _, _, executionContext, gate in
            let now = current.withLock { $0 += 1; return $0 }
            peak.withLock { $0 = max($0, now) }
            // Hold the slot until a full set is running, then a little longer so an extra Item could overlap.
            var spins = 0
            while current.withLock({ $0 }) < cores, spins < 10_000 { await Task.yield(); spins += 1 }
            for _ in 0..<20 { await Task.yield() }
            current.withLock { $0 -= 1 }
            return .optimized(Savings(originalBytes: 2, newBytes: 1), notes: [], output: URL(filePath: "/out"))
        }
        var events = queue.events.makeAsyncIterator()
        let items = (0..<20).map { Item(source: URL(filePath: "/in/\($0).jpg"), droppedRoot: nil) }
        await queue.enqueue(
            Batch(
                settings: EffectiveSettings(quality: 80, lossless: false, resizeRule: .none, keepMetadata: false),
                outputFormat: .original, destination: .exportFolder(URL(filePath: "/Export")), items: items))

        var processing: Set<Item.ID> = []
        var mostProcessing = 0
        while let event = await events.next() {
            if case .itemChanged(_, let id, let state) = event {
                if case .processing = state { processing.insert(id) } else { processing.remove(id) }
                mostProcessing = max(mostProcessing, processing.count)
            }
            if event == .idle { break }
        }

        #expect(peak.withLock { $0 } == cores)
        #expect(mostProcessing <= cores)
    }
}
