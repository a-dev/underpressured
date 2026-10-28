import UnderpressuredApplication
import Foundation
import Synchronization
import Testing
@testable import AppModel
import UnderpressuredCore
import QueueTestSupport

/// Crosses intake, Queue execution and Run presentation with gates instead of timing delays.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CombinedRunIntakeTests {
    @Test func laterExecutionIntervalRefreshesMarkedExportWithinHeldProductRun() async {
        let files = InMemoryFileAccess()
        let codec = FakeCodec()
        let export = URL(filePath: "/Export")
        let firstSource = URL(filePath: "/one/a.jpg")
        let secondSource = URL(filePath: "/two/a.jpg")
        let firstBytes = Data(repeating: 1, count: 1_000)
        let secondBytes = Data(repeating: 2, count: 1_000)
        let firstOutput = Data(repeating: 11, count: 400)
        let secondOutput = Data(repeating: 22, count: 300)
        files.addDirectory(export)
        files.addFile(firstSource, data: firstBytes)
        files.addFile(secondSource, data: secondBytes)
        codec.setEncode(.success(EncodedImage(data: firstOutput, format: .jpeg, pixelWidth: 100, pixelHeight: 100)), for: firstBytes)
        codec.setEncode(.success(EncodedImage(data: secondOutput, format: .jpeg, pixelWidth: 100, pixelHeight: 100)), for: secondBytes)
        let scanStarted = AsyncStream<Void>.makeStream()
        let releaseScan = DispatchSemaphore(value: 0)
        defer { releaseScan.signal() }
        let pipeline = Pipeline(fileAccess: files, codec: codec)
        codec.hold(.encode)
        let queue = Queue(parallelism: 1, pipeline: pipeline.itemPipeline)
        let notifier = RecordingNotifier()
        let model = AppModel(
            queue: queue,
            intake: { urls, _, _ in
                if urls[0] == secondSource {
                    scanStarted.continuation.yield(())
                    #expect(releaseScan.wait(timeout: .now() + 5) == .success)
                }
                return ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) })
            }, notifier: notifier, isFrontmost: { false }, updateInterval: .zero)
        model.destination = DestinationSettings(kind: .exportFolder, exportFolder: export)

        await model.open([firstSource])
        await codec.waitUntilStarted(.encode)
        let secondOpen = Task { await model.open([secondSource]) }
        var signals = scanStarted.stream.makeAsyncIterator()
        _ = await signals.next()
        codec.release(.encode)
        while model.runSummary?.finished == 0 { await Task.yield() }
        #expect(model.isRunning)
        #expect(model.banner == nil)
        #expect(notifier.posts.isEmpty)
        let drained = await queue.diagnostics
        #expect(!drained.hasExecutionContext && drained.reservedPaths == 0 && drained.cachedBatches == 0)
        #expect(files.data(at: URL(filePath: "/Export/a.jpg")) == firstOutput)
        releaseScan.signal()
        await secondOpen.value
        await model.untilIdle()

        #expect(model.rows.map(\.openURL) == [URL(filePath: "/Export/a.jpg"), URL(filePath: "/Export/a.jpg")])
        #expect(files.data(at: URL(filePath: "/Export/a.jpg")) == secondOutput)
        #expect(model.runSummary?.images == 2 && model.runSummary?.optimized == 2)
        #expect(notifier.posts.count == 1)
    }

    @Test(arguments: [1, 2])
    func overlappingSameNameInputsReserveDistinctOutputsEvenWhenFirstCommitsFirst(parallelism: Int) async {
        let files = InMemoryFileAccess()
        let codec = FakeCodec()
        let export = URL(filePath: "/Export")
        let first = URL(filePath: "/one/a.jpg")
        let second = URL(filePath: "/two/a.jpg")
        let firstBytes = Data(repeating: 3, count: 1_000)
        let secondBytes = Data(repeating: 4, count: 1_000)
        let firstOutput = Data(repeating: 31, count: 400)
        let secondOutput = Data(repeating: 42, count: 300)
        files.addDirectory(export)
        files.addFile(first, data: firstBytes)
        files.addFile(second, data: secondBytes)
        codec.setEncode(.success(EncodedImage(data: firstOutput, format: .jpeg, pixelWidth: 100, pixelHeight: 100)), for: firstBytes)
        codec.setEncode(.success(EncodedImage(data: secondOutput, format: .jpeg, pixelWidth: 100, pixelHeight: 100)), for: secondBytes)
        codec.hold(.encode)
        let pipeline = Pipeline(fileAccess: files, codec: codec)
        let model = AppModel(
            queue: Queue(parallelism: parallelism, pipeline: pipeline.itemPipeline),
            intake: { urls, _, _ in ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }) },
            updateInterval: .zero)
        model.destination = DestinationSettings(kind: .exportFolder, exportFolder: export)
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            codec.release(.encode)
        }
        defer { watchdog.cancel(); codec.release(.encode) }

        await model.open([first])
        await codec.waitUntilStarted(.encode)
        await model.open([second])
        if parallelism == 2 { await codec.waitUntilStarted(.encode, count: 2) }
        codec.release(.encode)
        await model.untilIdle()

        let firstOutputURL = URL(filePath: "/Export/a.jpg")
        let secondOutputURL = URL(filePath: "/Export/a-2.jpg")
        #expect(model.rows.map(\.openURL) == [firstOutputURL, secondOutputURL])
        #expect(files.data(at: firstOutputURL) == firstOutput)
        #expect(files.data(at: secondOutputURL) == secondOutput)
    }

    @Test func drainedQueueStaysInOneRunWhileTheNextScanIsHeld() async {
        let scanStarted = AsyncStream<Void>.makeStream()
        let releaseScan = DispatchSemaphore(value: 0)
        defer { releaseScan.signal() }
        let firstStarted = AsyncStream<Void>.makeStream()
        let releaseFirst = AsyncStream<Void>.makeStream()
        let processed = Mutex<[String]>([])
        let notifier = RecordingNotifier()
        let queue = Queue(parallelism: 1) { item, _, _, _ in
            processed.withLock { $0.append(item.source.lastPathComponent) }
            if item.source.lastPathComponent == "first.jpg" {
                firstStarted.continuation.yield(())
                var iterator = releaseFirst.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
            return .failed(.cantRead)
        }
        let model = AppModel(queue: queue, intake: { urls, _, _ in
            if urls[0].lastPathComponent == "second.jpg" {
                scanStarted.continuation.yield(())
                #expect(releaseScan.wait(timeout: .now() + 5) == .success)
            }
            return ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) })
        }, notifier: notifier, isFrontmost: { false }, updateInterval: .zero)

        await model.open([URL(filePath: "/first.jpg")])
        var firstSignals = firstStarted.stream.makeAsyncIterator()
        _ = await firstSignals.next()
        let secondOpen = Task { await model.open([URL(filePath: "/second.jpg")]) }
        var scanSignals = scanStarted.stream.makeAsyncIterator()
        _ = await scanSignals.next()
        releaseFirst.continuation.yield(())
        while model.runSummary?.finished == 0 { await Task.yield() }

        #expect(model.isRunning)
        #expect(model.banner == nil)
        #expect(notifier.posts.isEmpty)
        #expect(model.footer.progressText == "1 / 1")
        #expect((await queue.diagnostics).hasExecutionContext == false)

        releaseScan.signal()
        await secondOpen.value
        await model.untilIdle()
        #expect(processed.withLock { $0 } == ["first.jpg", "second.jpg"])
        #expect(model.rows.count == 2)
        #expect(model.runSummary?.images == 2)
        #expect(model.runSummary?.failed == 2)
        #expect(!model.isRunning)
        #expect(notifier.posts == [model.banner?.text])
    }

    @Test func cancelDuringHeldScanCannotAdmitItsLateResultOrReopenRun() async {
        let scanStarted = AsyncStream<Void>.makeStream()
        let releaseScan = DispatchSemaphore(value: 0)
        defer { releaseScan.signal() }
        let processed = Mutex(0)
        let notifier = RecordingNotifier()
        let model = AppModel(
            queue: Queue(parallelism: 1) { _, _, _, _ in
                processed.withLock { $0 += 1 }
                return .skipped(.alreadyOptimized, notes: [], output: nil)
            },
            intake: { urls, _, _ in
                scanStarted.continuation.yield(())
                #expect(releaseScan.wait(timeout: .now() + 5) == .success)
                return ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) })
            }, notifier: notifier, isFrontmost: { false }, updateInterval: .zero)

        let open = Task { await model.open([URL(filePath: "/cancelled.jpg")]) }
        var scanSignals = scanStarted.stream.makeAsyncIterator()
        _ = await scanSignals.next()
        await model.cancel()
        #expect(!model.isRunning)
        let postsAfterCancel = notifier.posts
        releaseScan.signal()
        await open.value
        await model.untilIdle()

        #expect(model.rows.isEmpty)
        #expect(processed.withLock { $0 } == 0)
        #expect(notifier.posts == postsAfterCancel)
        #expect(!model.isRunning)
    }

    @Test func emptyAndTerminalCandidatesSettleWithIgnoredCount() async {
        let model = AppModel(
            queue: Queue(parallelism: 1) { _, _, _, _ in
                Issue.record("A terminal intake candidate must not be processed")
                return .cancelled
            },
            intake: { urls, _, _ in
                let terminal = Item(source: urls[0], droppedRoot: nil, state: .finished(.cancelled))
                return ScanResult(items: [terminal], ignoredCount: 2)
            }, updateInterval: .zero)

        await model.open([URL(filePath: "/terminal.jpg")])
        await model.untilIdle()
        #expect(!model.isRunning)
        #expect(model.rows.map { $0.stateText } == ["Cancelled"])
        #expect(model.runSummary?.images == 1)
        #expect(model.runSummary?.cancelled == 1)
        #expect(model.runSummary?.ignored == 2)
        #expect(model.banner?.text.contains("2 other files ignored") == true)
    }

    @Test func ignoredOnlyScanSettlesWithoutCreatingImageRows() async {
        let model = AppModel(
            queue: Queue(parallelism: 1) { _, _, _, _ in
                Issue.record("An ignored-only scan must not enter the pipeline")
                return .cancelled
            },
            intake: { _, _, _ in ScanResult(ignoredCount: 4) },
            updateInterval: .zero)

        await model.open([URL(filePath: "/folder-with-no-images")])
        await model.untilIdle()
        #expect(!model.isRunning)
        #expect(model.rows.isEmpty)
        #expect(model.runSummary?.images == 0)
        #expect(model.runSummary?.ignored == 4)
        #expect(model.banner?.text.contains("4 other files ignored") == true)
    }

    @Test func freshIdleRunResetsProgressAndRetainsHistoricalBannerFilters() async {
        let secondStarted = AsyncStream<Void>.makeStream()
        let releaseSecond = AsyncStream<Void>.makeStream()
        let notifier = RecordingNotifier()
        let queue = Queue(parallelism: 1) { item, _, _, _ in
            if item.source.lastPathComponent == "second.jpg" {
                secondStarted.continuation.yield(())
                var iterator = releaseSecond.stream.makeAsyncIterator()
                _ = await iterator.next()
                return .skipped(.alreadyOptimized, notes: [], output: nil)
            }
            return .failed(.cantRead)
        }
        let model = AppModel(queue: queue, intake: { urls, _, _ in
            ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) })
        }, notifier: notifier, isFrontmost: { false }, updateInterval: .zero)

        await model.open([URL(filePath: "/first.jpg")])
        await model.untilIdle()
        let secondOpen = Task { await model.open([URL(filePath: "/second.jpg")]) }
        var signals = secondStarted.stream.makeAsyncIterator()
        _ = await signals.next()

        #expect(model.isRunning)
        #expect(model.runSummary?.images == 1)
        #expect(model.runSummary?.finished == 0)
        #expect(model.footer.progressText == "0 / 1")
        #expect(model.rows.map(\.name) == ["first.jpg", "second.jpg"])

        releaseSecond.continuation.yield(())
        await secondOpen.value
        await model.untilIdle()
        #expect(!model.isRunning)
        #expect(model.runSummary?.images == 1)
        #expect(model.runSummary?.skipped == 1)
        #expect(model.banner?.filters.map(\.filter) == [.failed, .skipped])
        #expect(notifier.posts.count == 2)
        #expect(notifier.posts.last == "1 image · nothing optimized · 1 skipped")
    }
}
