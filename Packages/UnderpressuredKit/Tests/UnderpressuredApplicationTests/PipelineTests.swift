import Foundation
import Synchronization
import Testing
import QueueTestSupport
import UniformTypeIdentifiers

@testable import UnderpressuredCore
@testable import UnderpressuredApplication

/// Each exit of spec §7.3 steps 1–10, with FakeCodec and InMemoryFileAccess.
struct PipelineTests {
    let files = InMemoryFileAccess()
    let codec = FakeCodec()
    let settings = EffectiveSettings(quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)
    let sourceBytes = Data(repeating: 7, count: 1000)
    let source = URL(filePath: "/in/a.jpg")
    let export = URL(filePath: "/Export")

    init() {
        files.addFile(source, data: sourceBytes, contentType: .jpeg, modificationDate: Date(timeIntervalSince1970: 1000))
        files.addDirectory(export)
    }

    private let executionContext = QueueExecutionContext()

    private var pipeline: Pipeline<FakeCodec> { Pipeline(fileAccess: files, codec: codec) }

    private func batch(
        _ destination: Destination, outputFormat: OutputFormat = .original, items: [Item]? = nil
    ) -> Batch {
        Batch(
            settings: settings, outputFormat: outputFormat, destination: destination,
            items: items ?? [Item(source: source, droppedRoot: nil)])
    }

    private static let openGate = StageGate { _ throws(CancellationError) in }

    private func run(_ batch: Batch, with pipeline: Pipeline<FakeCodec>? = nil, gate: StageGate = openGate) async -> Outcome {
        await (pipeline ?? self.pipeline).run(batch.items[0], in: batch.context, executionContext: executionContext, gate: gate)
    }

    private func mark(at url: URL) -> OptimizationMark? {
        try? files.markedOutput(at: url)?.mark
    }

    private func attachValidMark(to url: URL, format: WritableFormat = .jpeg) throws {
        let attributes = try files.attributes(of: url)
        let mark = OptimizationMark(
            settings: settings, outputFormat: format, size: attributes.size,
            modificationDate: attributes.modificationDate)
        try files.setOptimizationMark(mark, at: url)
    }

    // MARK: Step 1: read, recognise, mark check

    @Test func missingExportFolder_spec6_2_failsEveryItemOfTheBatch() async {
        let other = URL(filePath: "/in/b.jpg")
        files.addFile(other, data: sourceBytes, contentType: .jpeg)
        let missing = batch(
            .exportFolder(URL(filePath: "/Gone")),
            items: [Item(source: source, droppedRoot: nil), Item(source: other, droppedRoot: nil)])
        let pipeline = pipeline
        for item in missing.items {
            #expect(await pipeline.run(item, in: missing.context, executionContext: executionContext, gate: Self.openGate) == .failed(.exportFolderUnavailable))
        }
        #expect(codec.calls.isEmpty)
    }

    @Test func exportFolderCheckedOnceAtBatchStart_spec6_2() async {
        let pipeline = pipeline
        let b = batch(.exportFolder(export))
        _ = await run(b, with: pipeline)
        try? files.removeItem(at: export)
        // Later Items of the same Batch don't fail on their own: the check belongs to Batch start.
        #expect(await run(b, with: pipeline) != .failed(.exportFolderUnavailable))
    }

    @Test func unreadableSourceFile_preservesPermissionReason() async {
        files.fail(.permissionDenied, on: source, for: .read)
        #expect(await run(batch(.replaceOriginals(moveToTrash: false))) == .failed(.noPermission))
    }

    @Test(arguments: [FileAccessError.notFound, .alreadyExists, .permissionDenied, .diskFull, .other("internal details")])
    func filesystemFailuresPreserveReasonAndSource(_ error: FileAccessError) async {
        files.fail(error, on: source, for: .write)
        #expect(await run(batch(.replaceOriginals(moveToTrash: false))) == .failed(error.failReason))
        #expect(files.data(at: source) == sourceBytes)
    }

    @Test func missingSourceHasItsOwnReason() async throws {
        try files.removeItem(at: source)
        #expect(await run(batch(.replaceOriginals(moveToTrash: false))) == .failed(.fileNotFound))
        #expect(codec.calls.isEmpty)
    }

    @Test func inspectFails_spec7_3_failsCantRead() async {
        codec.setInspect(.failure(.unreadable))
        #expect(await run(batch(.replaceOriginals(moveToTrash: false))) == .failed(.cantRead))
    }

    @Test func animatedImage_spec7_2_skippedUnsupported() async {
        codec.setInspect(.success(ImageInfo(format: .png, pixelWidth: 10, pixelHeight: 10, frameCount: 3)))
        #expect(await run(batch(.replaceOriginals(moveToTrash: false))) == .skipped(.unsupported(.animated), notes: []))
        #expect(codec.count(.decode) == 0)
    }

    @Test func multiPageTIFF_spec7_2_skippedUnsupported() async {
        codec.setInspect(.success(ImageInfo(format: .tiff, pixelWidth: 10, pixelHeight: 10, frameCount: 2)))
        #expect(
            await run(batch(.replaceOriginals(moveToTrash: false), outputFormat: .jpeg))
                == .skipped(.unsupported(.multiPageTIFF), notes: []))
    }

    @Test func originalOfUnwritableFormat_spec5_skippedCantWriteYet() async {
        codec.setInspect(.success(ImageInfo(format: .heic, pixelWidth: 10, pixelHeight: 10)))
        #expect(await run(batch(.replaceOriginals(moveToTrash: false))) == .skipped(.cantWriteYet(.heic), notes: []))
    }

    @Test func validMatchingMark_spec7_3_skippedAlreadyOptimized() async throws {
        try attachValidMark(to: source)
        #expect(await run(batch(.replaceOriginals(moveToTrash: false))) == .skipped(.alreadyOptimized, notes: []))
        #expect(files.data(at: source) == sourceBytes)
        #expect(codec.count(.decode) == 0)
    }

    @Test func markForOtherSettings_spec7_5_isProcessed() async throws {
        let attributes = try files.attributes(of: source)
        var other = settings
        other.quality = Quality.clamping(50)
        let mark = OptimizationMark(
            settings: other, outputFormat: .jpeg, size: attributes.size, modificationDate: attributes.modificationDate)
        try files.setOptimizationMark(mark, at: source)
        guard case .optimized = await run(batch(.replaceOriginals(moveToTrash: false))) else {
            Issue.record("expected Optimized")
            return
        }
    }

    @Test func alreadyOptimizedInExport_spec6_2_copiedUnchangedWithFreshMark() async throws {
        try attachValidMark(to: source)
        let outcome = await run(batch(.exportFolder(export)))
        let copy = export.appending(path: "a.jpg")
        #expect(outcome == .skipped(.alreadyOptimized, notes: [.copiedUnchanged], output: copy))
        #expect(files.data(at: copy) == sourceBytes)
        let copied = try #require(mark(at: copy))
        #expect(copied.isValid(for: try files.attributes(of: copy)))
    }

    // MARK: Steps 2–7

    @Test func decodeFails_spec7_3_failsCantRead() async {
        codec.setDecode(.failure(.unreadable))
        #expect(await run(batch(.replaceOriginals(moveToTrash: false))) == .failed(.cantRead))
    }

    @Test func planningFails_spec7_3_failsWithWriteReason() async {
        // A format change plans a new file next to the source, which asks the folder's volume.
        files.fail(.permissionDenied, on: URL(filePath: "/in"), for: .read)
        let b = batch(.replaceOriginals(moveToTrash: false), outputFormat: .png)
        #expect(await run(b) == .failed(.noPermission))
    }

    @Test func transformFails_spec7_3_failsCantRead() async {
        codec.setTransform(.failure(.unreadable))
        #expect(await run(batch(.replaceOriginals(moveToTrash: false))) == .failed(.cantRead))
    }

    @Test func encodeFails_spec7_8_failsCouldntEncode() async {
        codec.setEncode(.failure(.encodeFailed("boom")))
        #expect(await run(batch(.replaceOriginals(moveToTrash: false))) == .failed(.encodeFailed))
        #expect(files.data(at: source) == sourceBytes)
    }

    @Test func transformAndEncodePlansFollowTheBatch_spec7_3() async {
        _ = await run(batch(.replaceOriginals(moveToTrash: false), outputFormat: .jpeg))
        let calls = codec.calls
        #expect(calls.contains(.transform(sourceBytes, TransformPlan(resizeRule: .none, flattenOntoWhite: true))))
        #expect(
            calls.contains(
                .encode(sourceBytes, EncodePlan(format: .jpeg, quality: 80, lossless: false, keepMetadata: false))))
    }

    // MARK: Step 8: not-smaller rule

    @Test func notSmaller_spec7_3_skippedAlreadyOptimal() async {
        codec.setEncode(.success(EncodedImage(data: Data(count: 1000), format: .jpeg, pixelWidth: 100, pixelHeight: 100)))
        #expect(await run(batch(.replaceOriginals(moveToTrash: false))) == .skipped(.alreadyOptimal, notes: []))
        #expect(files.data(at: source) == sourceBytes)
        #expect(mark(at: source) == nil)
    }

    @Test func notSmallerInExport_spec6_2_copiedUnchanged() async {
        codec.setEncode(.success(EncodedImage(data: Data(count: 2000), format: .jpeg, pixelWidth: 100, pixelHeight: 100)))
        #expect(
            await run(batch(.exportFolder(export)))
                == .skipped(.alreadyOptimal, notes: [.copiedUnchanged], output: export.appending(path: "a.jpg")))
        #expect(files.data(at: export.appending(path: "a.jpg")) == sourceBytes)
        #expect(mark(at: export.appending(path: "a.jpg")) != nil)
    }

    // MARK: Step 9: write

    @Test func replaceSameFormat_spec6_1_replacesSourceAndMarksIt() async throws {
        files.setTags(["Red"], at: source)
        let outcome = await run(batch(.replaceOriginals(moveToTrash: false)))
        #expect(outcome == .optimized(Savings(originalBytes: 1000, newBytes: 500), notes: [], output: source))
        #expect(files.data(at: source)?.count == 500)
        #expect(files.tags(at: source) == ["Red"])
        let attributes = try files.attributes(of: source)
        #expect(attributes.modificationDate == Date(timeIntervalSince1970: 1000))
        #expect(try #require(mark(at: source)).isValid(for: attributes))
        #expect(files.allPaths.filter { $0.hasPrefix("/.tmp/") }.isEmpty)
    }

    @Test func replaceWithFormatChange_spec6_1_writesNewThenRemovesSource() async {
        let outcome = await run(batch(.replaceOriginals(moveToTrash: false), outputFormat: .png))
        guard case .optimized = outcome else { Issue.record("got \(outcome)"); return }
        #expect(!files.exists(source))
        #expect(files.data(at: URL(filePath: "/in/a.png"))?.count == 500)
        #expect(files.trashed.isEmpty)
    }

    @Test func exportFolder_spec6_2_reportsTheOutputPath() async {
        let outcome = await run(batch(.exportFolder(export)))
        #expect(outcome == .optimized(
            Savings(originalBytes: 1000, newBytes: 500), notes: [], output: export.appending(path: "a.jpg")))
    }

    @Test func nameClash_spec6_3_reportsTheNumberedPath() async {
        files.addFile(export.appending(path: "a.jpg"), data: Data(count: 10), contentType: .jpeg)
        let outcome = await run(batch(.exportFolder(export)))
        guard case .optimized(_, _, let output) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(output == export.appending(path: "a-2.jpg"))
    }

    @Test func replaceWithTrash_spec6_1_movesSourceToTrash() async {
        _ = await run(batch(.replaceOriginals(moveToTrash: true)))
        #expect(files.trashed == [source])
        #expect(files.data(at: source)?.count == 500)
    }

    @Test func formatChangeWithTrash_spec6_1_trashesSourceAfterNewFile() async {
        _ = await run(batch(.replaceOriginals(moveToTrash: true), outputFormat: .png))
        #expect(files.trashed == [source])
        #expect(files.exists(URL(filePath: "/in/a.png")))
    }

    @Test func noTrashOnVolume_spec6_1_failsAndChangesNothing() async {
        files.setHasTrash(false)
        #expect(await run(batch(.replaceOriginals(moveToTrash: true))) == .failed(.noTrash))
        #expect(files.data(at: source) == sourceBytes)
        #expect(files.allPaths.filter { $0.hasPrefix("/.tmp/") }.isEmpty)
    }

    @Test func sourceChangedWhileProcessing_spec7_3_failsAndLeavesNoTemporaryFile() async {
        codec.hold(.encode)
        let b = batch(.replaceOriginals(moveToTrash: false))
        let pipeline = pipeline
        async let outcome = pipeline.run(b.items[0], in: b.context, executionContext: executionContext, gate: Self.openGate)
        await codec.waitUntilStarted(.encode)
        files.now = Date(timeIntervalSince1970: 5000)
        files.addFile(source, data: Data(repeating: 9, count: 1000), contentType: .jpeg)
        codec.release(.encode)
        #expect(await outcome == .failed(.fileChanged))
        #expect(files.data(at: source) == Data(repeating: 9, count: 1000))
        #expect(files.allPaths.filter { $0.hasPrefix("/.tmp/") }.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["edit", "date", "replace", "delete", "symlink", "mark"])
    func markedDestinationChangedDuringEncoding(_ change: String) async throws {
        let target = export.appending(path: "a.jpg")
        files.addFile(target, data: Data(repeating: 1, count: 100))
        try attachValidMark(to: target)
        let original = try files.attributes(of: target)
        codec.hold(.encode)
        defer { codec.release(.encode) }
        let b = batch(.exportFolder(export))
        let task = Task { await run(b) }
        await codec.waitUntilStarted(.encode)
        switch change {
        case "delete": try files.removeItem(at: target)
        case "replace":
            try files.removeItem(at: target)
            files.addFile(target, data: Data(repeating: 9, count: 100), modificationDate: original.modificationDate)
            try attachValidMark(to: target)
        case "symlink": files.addSymlink(target, to: source)
        case "date": files.addFile(target, data: Data(repeating: 9, count: 100), modificationDate: original.modificationDate.addingTimeInterval(1))
        case "mark": try files.setExtendedAttribute("app.underpressured.mark", to: Data(), at: target)
        default: files.addFile(target, data: Data(repeating: 9, count: 101))
        }
        let remaining = files.data(at: target)
        codec.release(.encode)
        #expect(await task.value == .failed(.destinationChanged))
        #expect(files.data(at: target) == remaining)
        #expect(files.data(at: source) == sourceBytes)
        #expect(files.allPaths.filter { $0.hasPrefix("/.tmp/") }.isEmpty)
    }

    @Test(arguments: [false, true])
    func convertedOutputCommitFailurePreservesOriginal(_ trash: Bool) async {
        let visits = Mutex(0)
        let gate = StageGate { [files] stage throws(CancellationError) in
            if stage == .writing, visits.withLock({ $0 += 1; return $0 }) == 2 {
                // The second writing checkpoint follows temporary-file preparation.
                // Fail only the final rename, so preparation must really succeed.
                let temps = files.allPaths.filter { $0.hasPrefix("/.tmp/") }
                #expect(temps.count == 1)
                for path in temps {
                    files.fail(.permissionDenied, on: URL(filePath: path), for: .move)
                }
            }
        }
        let outcome = await run(
            batch(.replaceOriginals(moveToTrash: trash), outputFormat: .png), gate: gate)
        #expect(visits.withLock { $0 } == 2)
        #expect(outcome == .failed(.noPermission))
        #expect(files.data(at: source) == sourceBytes)
        #expect(files.trashed.isEmpty)
        #expect(!files.cleanupAttempts.contains(source))
        #expect(!files.exists(URL(filePath: "/in/a.png")))
        #expect(files.allPaths.filter { $0.hasPrefix("/.tmp/") }.isEmpty)
    }

    @Test(arguments: [false, true])
    func committedConversionReportsOutputWhenSourceCleanupFails(_ trash: Bool) async {
        files.fail(.permissionDenied, on: source, for: trash ? .trash : .remove)
        let outcome = await run(batch(.replaceOriginals(moveToTrash: trash), outputFormat: .png))
        guard case .optimized(_, let notes, let output) = outcome else {
            Issue.record("Expected committed output, got \(outcome)")
            return
        }
        #expect(output == URL(filePath: "/in/a.png"))
        #expect(files.data(at: output)?.count == 500)
        #expect(files.data(at: source) == sourceBytes)
        #expect(notes.contains(.sourceCleanupFailed))
    }

    @Test func renameFailureCleansTemporaryFileAndPreservesTarget() async throws {
        let target = export.appending(path: "a.jpg")
        let old = Data(repeating: 1, count: 100)
        files.addFile(target, data: old)
        try attachValidMark(to: target)
        files.fail(.permissionDenied, on: target, for: .replace)
        #expect(await run(batch(.exportFolder(export))) == .failed(.noPermission))
        #expect(files.data(at: target) == old)
        #expect(files.allPaths.filter { $0.hasPrefix("/.tmp/") }.isEmpty)
    }

    @Test func writeDenied_spec7_8_failsNoPermission() async {
        files.fail(.permissionDenied, on: source, for: .write)
        #expect(await run(batch(.replaceOriginals(moveToTrash: false))) == .failed(.noPermission))
        #expect(files.data(at: source) == sourceBytes)
        #expect(files.allPaths.filter { $0.hasPrefix("/.tmp/") }.isEmpty)
    }

    @Test func diskFull_spec7_8_failsNotEnoughSpace() async {
        files.fail(.diskFull, on: export.appending(path: "a.jpg"), for: .write)
        #expect(await run(batch(.exportFolder(export))) == .failed(.diskFull))
    }

    @Test func exportMirrorsDroppedFolder_spec6_2() async throws {
        let nested = URL(filePath: "/in/Trip/day1/b.jpg")
        files.addFile(nested, data: sourceBytes, contentType: .jpeg)
        let b = batch(.exportFolder(export), items: [Item(source: nested, droppedRoot: URL(filePath: "/in/Trip"))])
        _ = await run(b)
        let output = URL(filePath: "/Export/Trip/day1/b.jpg")
        #expect(files.data(at: output)?.count == 500)
        #expect(files.data(at: nested) == sourceBytes)
        #expect(try #require(mark(at: output)).isValid(for: try files.attributes(of: output)))
    }

    @Test func twoItemsWantingOneName_spec6_3_getNumbered() async {
        let other = URL(filePath: "/in2/a.jpg")
        files.addFile(other, data: sourceBytes, contentType: .jpeg)
        let b = batch(
            .exportFolder(export), items: [Item(source: source, droppedRoot: nil), Item(source: other, droppedRoot: nil)])
        let pipeline = pipeline
        for item in b.items { _ = await pipeline.run(item, in: b.context, executionContext: executionContext, gate: Self.openGate) }
        #expect(files.exists(URL(filePath: "/Export/a.jpg")))
        #expect(files.exists(URL(filePath: "/Export/a-2.jpg")))
    }

    // MARK: Cancel

    @Test(arguments: Stage.allCases)
    func cancelAtStage_spec7_6_leavesSourceAndNoTemporaryFile(_ stage: Stage) async {
        let gate = StageGate { entered throws(CancellationError) in
            if entered == stage { throw CancellationError() }
        }
        #expect(await run(batch(.replaceOriginals(moveToTrash: false)), gate: gate) == .cancelled)
        #expect(files.data(at: source) == sourceBytes)
        #expect(files.allPaths.filter { $0.hasPrefix("/.tmp/") }.isEmpty)
    }

    // MARK: Queue wiring

    @Test func queueRunsThePipeline_spec7_3() async {
        let queue = Queue(parallelism: 2, pixelBudget: 1_000_000, pipeline: pipeline.itemPipeline)
        await queue.enqueue(batch(.replaceOriginals(moveToTrash: false)))
        let history = await QueueEventHistory.collect(untilIdle: queue.events)
        let states = history.batches.flatMap { $0.items.map(\.state) }
        #expect(states == [.finished(.optimized(Savings(originalBytes: 1000, newBytes: 500), notes: [], output: source))])
    }
}


extension PipelineTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["normal", "optimal", "marked"], [1, 2])
    func everyWriteChecksCancellationBeforeAdmissionAndCommit(_ path: String, _ boundary: Int) async throws {
        if path == "marked" { try attachValidMark(to: source) }
        if path == "optimal" {
            codec.setEncode(.success(EncodedImage(data: sourceBytes, format: .jpeg, pixelWidth: 100, pixelHeight: 100)))
        }
        let visits = Mutex(0)
        let gate = StageGate { stage throws(CancellationError) in
            if stage == .writing {
                let count = visits.withLock { $0 += 1; return $0 }
                if count == boundary { throw CancellationError() }
            }
        }
        #expect(await run(batch(.exportFolder(export)), gate: gate) == .cancelled)
        #expect(files.data(at: export.appending(path: "a.jpg")) == nil)
        #expect(files.data(at: source) == sourceBytes)
        #expect(!files.allPaths.contains { $0.hasPrefix("/.tmp/") })
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["optimal", "marked"])
    func cancelHeldShortcutDiscardsCodecResult(_ path: String) async throws {
        let operation: FakeCodec.Operation = path == "marked" ? .inspect : .encode
        if path == "marked" { try attachValidMark(to: source) }
        codec.setEncode(.success(EncodedImage(data: sourceBytes, format: .jpeg, pixelWidth: 100, pixelHeight: 100)))
        codec.hold(operation)
        defer { codec.release(operation) }
        let queue = Queue(parallelism: 1, pipeline: pipeline.itemPipeline)
        await queue.enqueue(batch(.exportFolder(export)))
        await codec.waitUntilStarted(operation)
        await queue.cancel()
        codec.release(operation)
        let history = await QueueEventHistory.collect(untilIdle: queue.events)
        #expect(history.batches.first?.items.first?.state == .finished(.cancelled))
        #expect(files.data(at: export.appending(path: "a.jpg")) == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["normal", "optimal", "marked"])
    func cancellationAfterCommitPreservesOutput(_ path: String) async throws {
        if path == "marked" { try attachValidMark(to: source) }
        if path == "optimal" {
            codec.setEncode(.success(EncodedImage(data: sourceBytes, format: .jpeg, pixelWidth: 100, pixelHeight: 100)))
        }
        let returned = FakeCodec()
        returned.hold(.inspect)
        defer { returned.release(.inspect) }
        let process = pipeline.itemPipeline
        let queue = Queue(parallelism: 1) { item, batch, executionContext, gate in
            let outcome = await process(item, batch, executionContext, gate)
            _ = try? await returned.inspect(Data())
            return outcome
        }
        await queue.enqueue(batch(.exportFolder(export)))
        await returned.waitUntilStarted(.inspect)
        await queue.cancel()
        returned.release(.inspect)
        let history = await QueueEventHistory.collect(untilIdle: queue.events)
        let state = try #require(history.batches.first?.items.first?.state)
        let output = export.appending(path: "a.jpg")
        if path == "normal" {
            #expect(state == .finished(.optimized(Savings(originalBytes: 1000, newBytes: 500), notes: [], output: output)))
        } else {
            #expect(state == .finished(.skipped(path == "marked" ? .alreadyOptimized : .alreadyOptimal, notes: [.copiedUnchanged], output: output)))
        }
        #expect(files.data(at: output) == (path == "normal" ? Data(count: 500) : sourceBytes))
    }
}


extension PipelineTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["normal", "optimal", "marked"])
    func queueCancellationAfterTemporaryPreparationRemovesTemporaryOutput(_ path: String) async throws {
        if path == "marked" { try attachValidMark(to: source) }
        if path == "optimal" {
            codec.setEncode(.success(EncodedImage(data: sourceBytes, format: .jpeg, pixelWidth: 100, pixelHeight: 100)))
        }
        let prepared = FakeCodec()
        prepared.hold(.inspect)
        defer { prepared.release(.inspect) }
        let pipeline = pipeline
        let queue = Queue(parallelism: 1) { item, batch, executionContext, gate in
            let visits = Mutex(0)
            let intercepted = StageGate(
                enter: { stage throws(CancellationError) in
                    if stage == .writing, visits.withLock({ $0 += 1; return $0 }) == 2 {
                        _ = try? await prepared.inspect(Data())
                    }
                    try await gate.enter(stage)
                },
                didCommit: { gate.committed() },
                reservePixels: { pixels throws(CancellationError) in try await gate.reservePixels(pixels) })
            return await pipeline.run(item, in: batch, executionContext: executionContext, gate: intercepted)
        }
        await queue.enqueue(batch(.exportFolder(export)))
        await prepared.waitUntilStarted(.inspect)
        #expect(files.allPaths.contains { $0.hasPrefix("/.tmp/") })
        await queue.cancel()
        prepared.release(.inspect)
        let history = await QueueEventHistory.collect(untilIdle: queue.events)
        #expect(history.batches.first?.items.first?.state == .finished(.cancelled))
        #expect(files.data(at: source) == sourceBytes)
        #expect(files.data(at: export.appending(path: "a.jpg")) == nil)
        #expect(!files.allPaths.contains { $0.hasPrefix("/.tmp/") })
    }
}
