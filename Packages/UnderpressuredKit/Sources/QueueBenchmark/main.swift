import UnderpressuredApplication
import Foundation
import UnderpressuredCore

@main
struct QueueBenchmark {
    static let sizes = [1_000, 5_000, 10_000]
    static let repeats = 5

    static func main() async {
        print("items,repeat,elapsed_ms,admissions,waiting_visits,state_lookups,finishes,pixel_waiter_visits,remaining_items,remaining_batches,waiting_slots,pixel_waiter_slots,active_sources,has_run")
        if ProcessInfo.processInfo.environment["T8_PROFILE_MODE"] == "1" {
            await run(size: 1_000, repetition: 1)
            FileHandle.standardError.write(Data("T8_PROFILE_READY\n".utf8))
        } else {
            for size in sizes {
                for repetition in 1...repeats {
                    await run(size: size, repetition: repetition)
                }
            }
            await repeatedCycleCheck()
        }
        if let delay = ProcessInfo.processInfo.environment["T8_PROFILE_HOLD_SECONDS"].flatMap(Double.init), delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    static func run(size: Int, repetition: Int) async {
        let queue = Queue(parallelism: 8) { _, _, executionContext, _ in
            .skipped(.alreadyOptimized, notes: [])
        }
        var iterator = queue.events.makeAsyncIterator()
        let items = (0..<size).map { index in
            Item(source: URL(filePath: "/queue-benchmark/run-\(repetition)/item-\(index).jpg"), droppedRoot: nil)
        }
        let batch = Batch(
            settings: EffectiveSettings(quality: Quality.clamping(80), lossless: false, resizeRule: .none, keepMetadata: false),
            outputFormat: .original,
            destination: .exportFolder(URL(filePath: "/queue-benchmark/export")),
            items: items
        )
        let clock = ContinuousClock()
        let start = clock.now
        await queue.enqueue(batch)
        var terminalEvents = 0
        var idleReached = false
        while let event = await iterator.next() {
            switch event {
            case .itemChanged(_, _, let state):
                if state.isFinished { terminalEvents += 1 }
            case .idle:
                idleReached = true
            case .batchAdded:
                break
            }
            if idleReached { break }
        }
        let elapsed = start.duration(to: clock.now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        let diagnostics = await queue.diagnostics
        let work = diagnostics.work
        let valid = idleReached && terminalEvents == size
        print("\(size),\(repetition),\(String(format: "%.3f", milliseconds)),\(work.admissions),\(work.waitingVisits),\(work.stateLookups),\(work.finishes),\(work.pixelWaiterVisits),\(diagnostics.items),\(diagnostics.batches),\(diagnostics.waitingSlots),\(diagnostics.pixelWaiterSlots),\(diagnostics.activeSources),\(diagnostics.hasExecutionContext)")
        if !valid {
            fputs("benchmark failed to drain: size=\(size), terminalEvents=\(terminalEvents), idle=\(idleReached)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    static func repeatedCycleCheck() async {
        let cycles = 100
        let queue = Queue(parallelism: 8) { _, _, executionContext, _ in
            .skipped(.alreadyOptimized, notes: [])
        }
        var iterator = queue.events.makeAsyncIterator()
        for cycle in 0..<cycles {
            let batch = Batch(
                settings: EffectiveSettings(quality: Quality.clamping(80), lossless: false, resizeRule: .none, keepMetadata: false),
                outputFormat: .original,
                destination: .exportFolder(URL(filePath: "/queue-benchmark/export")),
                items: (0..<100).map { index in
                    Item(source: URL(filePath: "/queue-benchmark/cycle-\(cycle)/item-\(index).jpg"), droppedRoot: nil)
                }
            )
            await queue.enqueue(batch)
            var terminalEvents = 0
            while let event = await iterator.next() {
                if case .itemChanged(_, _, let state) = event, state.isFinished { terminalEvents += 1 }
                if event == .idle { break }
            }
            if terminalEvents != 100 {
                fputs("cycle drain failed: cycle=\(cycle), terminalEvents=\(terminalEvents)\n", stderr)
                exit(EXIT_FAILURE)
            }
            let diagnostics = await queue.diagnostics
            if diagnostics.items != 0 || diagnostics.batches != 0 || diagnostics.waitingSlots != 0
                || diagnostics.pixelWaiterSlots != 0 || diagnostics.activeSources != 0 || diagnostics.hasExecutionContext {
                fputs("retained queue state after cycle \(cycle): \(diagnostics)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        let diagnostics = await queue.diagnostics
        print("# repeated_cycles=\(cycles),items_per_cycle=100,active_records_after_last_cycle=\(diagnostics.items),batches_after_last_cycle=\(diagnostics.batches),waiting_slots_after_last_cycle=\(diagnostics.waitingSlots),pixel_waiter_slots_after_last_cycle=\(diagnostics.pixelWaiterSlots),active_sources_after_last_cycle=\(diagnostics.activeSources),has_run_after_last_cycle=\(diagnostics.hasExecutionContext)")
    }
}
