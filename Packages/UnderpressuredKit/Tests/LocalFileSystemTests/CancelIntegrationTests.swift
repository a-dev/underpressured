import Foundation
import Synchronization
import Testing
import UnderpressuredCore
@testable import UnderpressuredApplication

import QueueTestSupport
@testable import LocalFileSystem

/// A codec over opaque bytes that pauses inside one call until released, so a test can Cancel
/// while an Item is in that stage.
final class PausableCodec: ImageCodec, Sendable {
    typealias Image = Data
    enum Call: Sendable, CaseIterable { case inspect, decode, transform, encode }

    let unchanged: Bool
    let pauseAt: Call
    private let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let gate = Mutex<(waiter: CheckedContinuation<Void, Never>?, open: Bool)>((nil, false))

    init(pauseAt: Call, unchanged: Bool = false) {
        self.unchanged = unchanged
        self.pauseAt = pauseAt
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    func waitUntilPaused() async {
        for await _ in started { return }
    }

    func release() {
        let waiter = gate.withLock { state in
            state.open = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    private func pause(_ call: Call) async {
        guard call == pauseAt else { return }
        startedContinuation.yield()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let open = gate.withLock { state in
                if !state.open { state.waiter = continuation }
                return state.open
            }
            if open { continuation.resume() }
        }
    }

    func inspect(_ data: Data) async throws(CodecError) -> ImageInfo {
        await pause(.inspect)
        return ImageInfo(format: .jpeg, pixelWidth: 4, pixelHeight: 4)
    }

    func decode(_ data: Data) async throws(CodecError) -> Data {
        await pause(.decode)
        return data
    }

    func transform(_ image: Data, _ plan: TransformPlan) async throws(CodecError) -> Data {
        await pause(.transform)
        return image
    }

    func encode(_ image: Data, _ plan: EncodePlan) async throws(CodecError) -> EncodedImage {
        await pause(.encode)
        return EncodedImage(data: unchanged ? image : image.prefix(image.count / 2), format: .jpeg, pixelWidth: 4, pixelHeight: 4)
    }
}

/// Cancel in the middle of an Item, through the real Queue, Pipeline and file system (§7.6, §8).
final class CancelIntegrationTests {
    let root: URL
    private let sourceBytes = Data((0..<4096).map { UInt8($0 % 251) })

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("up-CancelIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private static let settings = EffectiveSettings(
        quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)

    /// Every file and folder under `root`, hidden ones included, relative to it.
    private func allPaths() -> [String] {
        let items = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
        return items.sorted()
    }

    @Test(arguments: PausableCodec.Call.allCases, [false, true])
    func cancelMidItem_spec7_6_leavesNoTemporaryOrPartialFileAndTheSourceUntouched(
        _ call: PausableCodec.Call, exporting: Bool
    ) async throws {
        let folder = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let source = folder.appendingPathComponent("photo.jpg")
        try sourceBytes.write(to: source)
        let before = try LocalFileAccess().attributes(of: source)
        let export = root.appendingPathComponent("Export")
        if exporting { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: false) }
        let pathsBefore = allPaths()

        let codec = PausableCodec(pauseAt: call)
        let access = LocalFileAccess()
        let pipeline = Pipeline(fileAccess: access, codec: codec)
        let queue = Queue(parallelism: 1, pixelBudget: .max, pipeline: pipeline.itemPipeline)
        let idle = Task { await QueueEventHistory.collect(untilIdle: queue.events) }
        let batch = Batch(
            settings: Self.settings, outputFormat: .original,
            destination: exporting ? .exportFolder(export) : .replaceOriginals(moveToTrash: false),
            items: [Item(source: source, droppedRoot: folder)])

        await queue.enqueue(batch)
        await codec.waitUntilPaused()
        await queue.cancel()
        codec.release()
        let history = await idle.value

        let outcome = history.batches.first?.items.first?.state
        #expect(outcome == .finished(.cancelled))
        #expect(allPaths() == pathsBefore, "no temporary file, no partial output")
        #expect(access.pendingTemporaryFiles.isEmpty, "no temporary file")
        #expect(try Data(contentsOf: source) == sourceBytes)
        let after = try LocalFileAccess().attributes(of: source)
        #expect(after.modificationDate == before.modificationDate)
        #expect(after.fileIdentity == before.fileIdentity)
        #expect(try LocalFileAccess().markedOutput(at: source) == nil)
    }
}

extension CancelIntegrationTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["edit", "replace", "delete", "symlink"])
    func destinationChangedDuringRealPipelineEncoding(_ change: String) async throws {
        let access = LocalFileAccess()
        let source = root.appendingPathComponent("source.jpg")
        let export = root.appendingPathComponent("export")
        try sourceBytes.write(to: source)
        try access.createDirectory(at: export)
        let target = export.appendingPathComponent("source.jpg")
        try Data("old output".utf8).write(to: target)
        let attributes = try access.attributes(of: target)
        let mark = OptimizationMark(settings: Self.settings, outputFormat: .jpeg,
                                    size: attributes.size, modificationDate: attributes.modificationDate)
        try access.setOptimizationMark(mark, at: target)
        let codec = PausableCodec(pauseAt: .encode)
        defer { codec.release() }
        let pipeline = Pipeline(fileAccess: access, codec: codec)
        let item = Item(source: source, droppedRoot: nil)
        let batch = Batch(settings: Self.settings, outputFormat: .original,
                          destination: .exportFolder(export), items: [item])
        let task = Task { await pipeline.run(item, in: batch.context, executionContext: QueueExecutionContext(), gate: StageGate { _ throws(CancellationError) in }) }
        await codec.waitUntilPaused()
        switch change {
        case "edit": try Data("unrelated edit".utf8).write(to: target)
        case "replace":
            let replacement = try access.writeTemporaryFile(Data("unrelated replacement".utf8), near: target)
            try access.replaceItem(at: target, withItemAt: replacement)
        case "delete": try access.removeItem(at: target)
        default:
            try access.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
        }
        let remaining = try? Data(contentsOf: target)
        codec.release()
        #expect(await task.value == .failed(.destinationChanged))
        #expect((try? Data(contentsOf: target)) == remaining)
        #expect(try Data(contentsOf: source) == sourceBytes)
        #expect(!allPaths().contains { $0.hasSuffix(".tmp") })
        #expect(access.pendingTemporaryFiles.isEmpty)
    }
}


extension CancelIntegrationTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancelHeldExportShortcutLeavesRealDiskUntouched(_ marked: Bool) async throws {
        let access = LocalFileAccess()
        let source = root.appendingPathComponent("shortcut.jpg")
        let export = root.appendingPathComponent("export")
        try sourceBytes.write(to: source)
        try access.createDirectory(at: export)
        if marked {
            let attributes = try access.attributes(of: source)
            let mark = OptimizationMark(settings: Self.settings, outputFormat: .jpeg,
                                        size: attributes.size, modificationDate: attributes.modificationDate)
            try access.setOptimizationMark(mark, at: source)
        }
        let before = allPaths()
        let codec = PausableCodec(pauseAt: marked ? .inspect : .encode, unchanged: true)
        defer { codec.release() }
        let pipeline = Pipeline(fileAccess: access, codec: codec)
        let queue = Queue(parallelism: 1, pipeline: pipeline.itemPipeline)
        await queue.enqueue(Batch(settings: Self.settings, outputFormat: .original,
                                  destination: .exportFolder(export), items: [Item(source: source, droppedRoot: nil)]))
        await codec.waitUntilPaused()
        await queue.cancel()
        codec.release()
        let history = await QueueEventHistory.collect(untilIdle: queue.events)
        #expect(history.batches.first?.items.first?.state == .finished(.cancelled))
        #expect(allPaths() == before)
        #expect(access.pendingTemporaryFiles.isEmpty)
        #expect(try Data(contentsOf: source) == sourceBytes)
    }
}


extension CancelIntegrationTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["normal", "optimal", "marked"])
    func cancelledAfterRealCommitKeepsOpenableOutput(_ path: String) async throws {
        let access = LocalFileAccess()
        let source = root.appendingPathComponent("committed.jpg")
        let export = root.appendingPathComponent("export")
        try sourceBytes.write(to: source)
        try access.createDirectory(at: export)
        if path == "marked" {
            let attributes = try access.attributes(of: source)
            let mark = OptimizationMark(settings: Self.settings, outputFormat: .jpeg,
                                        size: attributes.size, modificationDate: attributes.modificationDate)
            try access.setOptimizationMark(mark, at: source)
        }
        let codec = PausableCodec(pauseAt: .encode, unchanged: path != "normal")
        codec.release()
        let returned = PausableCodec(pauseAt: .inspect)
        defer { returned.release() }
        let process = Pipeline(fileAccess: access, codec: codec).itemPipeline
        let queue = Queue(parallelism: 1) { item, batch, executionContext, gate in
            let outcome = await process(item, batch, executionContext, gate)
            _ = try? await returned.inspect(Data())
            return outcome
        }
        await queue.enqueue(Batch(settings: Self.settings, outputFormat: .original,
                                  destination: .exportFolder(export), items: [Item(source: source, droppedRoot: nil)]))
        await returned.waitUntilPaused()
        await queue.cancel()
        returned.release()
        let history = await QueueEventHistory.collect(untilIdle: queue.events)
        let state = try #require(history.batches.first?.items.first?.state)
        let output: URL
        switch state {
        case .finished(.optimized(_, _, let url)): output = url
        case .finished(.skipped(_, _, let url)): output = try #require(url)
        default: Issue.record("Committed output was lost: \(state)"); return
        }
        #expect(try Data(contentsOf: output) == (path == "normal" ? sourceBytes.prefix(sourceBytes.count / 2) : sourceBytes))
        #expect(try Data(contentsOf: source) == sourceBytes)
        #expect(!allPaths().contains { $0.hasSuffix(".tmp") })
        #expect(access.pendingTemporaryFiles.isEmpty)
    }
}
