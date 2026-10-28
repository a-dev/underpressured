import Foundation
import UnderpressuredCore

@main
struct QueueBaseline {
    static func main() async {
        print("items,repeat,elapsed_ms,terminal_events")
        await run(size: 1_000, repetition: 1)
        FileHandle.standardError.write(Data("T8_PROFILE_READY\n".utf8))
        if let delay = ProcessInfo.processInfo.environment["T8_PROFILE_HOLD_SECONDS"].flatMap(Double.init), delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    static func run(size: Int, repetition: Int) async {
        let queue = Queue(parallelism: 8) { _, _, _ in .skipped(.alreadyOptimized, notes: []) }
        var iterator = queue.events.makeAsyncIterator()
        let batch = Batch(
            settings: EffectiveSettings(quality: 80, lossless: false, resizeRule: .none, keepMetadata: false),
            outputFormat: .original,
            destination: .exportFolder(URL(filePath: "/queue-benchmark/export")),
            items: (0..<size).map { index in
                Item(source: URL(filePath: "/queue-benchmark/run-\(repetition)/item-\(index).jpg"), droppedRoot: nil)
            }
        )
        let start = ContinuousClock.now
        await queue.enqueue(batch)
        var terminalEvents = 0
        while let event = await iterator.next() {
            if case .itemChanged(_, _, let state) = event, state.isFinished { terminalEvents += 1 }
            if event == .idle { break }
        }
        let elapsed = start.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        print("\(size),\(repetition),\(String(format: "%.3f", milliseconds)),\(terminalEvents)")
        if terminalEvents != size { exit(EXIT_FAILURE) }
    }
}
