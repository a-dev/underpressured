import UnderpressuredApplication
import Foundation
import Synchronization
import Testing
@testable import AppModel
import UnderpressuredCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct IntakeOrderTests {
    @Test func serialScanAdmissionAndSettingsFollowArrivalOrder() async {
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let scanned = Mutex<[String]>([])
        let scannedExports = Mutex<[URL?]>([])
        let firstExport = URL(filePath: "/export-first")
        let secondExport = URL(filePath: "/export-second")
        let laterExport = URL(filePath: "/export-later")
        let processedContexts = Mutex<[BatchContext]>([])
        let queue = Queue(parallelism: 1) { item, context, executionContext, _ in
            processedContexts.withLock { $0.append(context) }
            return .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: item.source)
        }
        let model = AppModel(queue: queue, intake: { urls, export, _ in
            let name = urls[0].lastPathComponent
            scanned.withLock { $0.append(name) }
            scannedExports.withLock { $0.append(export) }
            if name == "a.jpg" {
                started.continuation.yield(())
                // A failed test cannot leave the detached scanner blocked indefinitely.
                _ = release.wait(timeout: .now() + 5)
            }
            return ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) })
        }, updateInterval: .zero)
        model.destination = DestinationSettings(kind: .exportFolder, exportFolder: firstExport)
        let originalFormat = model.outputFormat
        let a = Task { await model.open([URL(filePath: "/a.jpg")]) }
        var signals = started.stream.makeAsyncIterator()
        _ = await signals.next()
        model.outputFormat = .png
        model.destination = DestinationSettings(kind: .exportFolder, exportFolder: secondExport)
        let b = Task { await model.open([URL(filePath: "/b.jpg")]) }
        // Both requests have entered open before releasing the first scan.
        while model.pendingScans < 2, !Task.isCancelled { await Task.yield() }
        #expect(model.pendingScans == 2)
        model.destination = DestinationSettings(kind: .exportFolder, exportFolder: laterExport)
        model.outputFormat = originalFormat
        #expect(scanned.withLock { $0 } == ["a.jpg"])
        release.signal()
        await a.value
        await b.value
        await model.untilIdle()
        #expect(scanned.withLock { $0 } == ["a.jpg", "b.jpg"])
        #expect(scannedExports.withLock { $0 } == [firstExport, secondExport])
        let contexts = processedContexts.withLock { $0 }
        #expect(contexts.map(\.destination) == [.exportFolder(firstExport), .exportFolder(secondExport)])
        #expect(model.rows.map(\.name) == ["a.jpg", "b.jpg"])
        #expect(model.sections.map(\.outputFormat) == [originalFormat, .png])
        #expect(contexts.map(\.outputFormat) == [originalFormat, .png])
    }
}
