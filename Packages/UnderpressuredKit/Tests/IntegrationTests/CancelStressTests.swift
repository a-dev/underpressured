import UnderpressuredApplication
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UnderpressuredCore
import QueueTestSupport

@testable import ImageEngine
@testable import LocalFileSystem

/// Cancel at random moments under real concurrency (plan 6.3, §7.6, §8 Safety): the real Queue,
/// Pipeline, LocalFileAccess and NativeCodec on small images, both Destinations.
@Suite(.timeLimit(.minutes(10)))
final class CancelStressTests {
    let root: URL
    let files = LocalFileAccess()
    let sources: [(name: String, data: Data)]

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("up-CancelStressTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
        let jpeg = EndToEndTests.encode(EndToEndTests.image(width: 96, height: 64), as: .jpeg)
        let png = EndToEndTests.encode(EndToEndTests.image(width: 48, height: 48), as: .png)
        sources = (0..<6).map { ("a\($0).jpg", jpeg) } + (0..<2).map { ("b\($0).png", png) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    struct DelayGenerator {
        var state: UInt64
        mutating func next() -> Int {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return Int((value ^ (value >> 31)) % 20_000)
        }
    }

    struct Snapshot {
        let item: Item
        let bytes: Data
        let modified: Date
        let created: Date
        let width: Int
        let height: Int
        let type: String
    }

    @Test(arguments: [false, true])
    func cancellationPreservesSourcesAndReportedOutputs(export: Bool) async throws {
        let root = self.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ProcessInfo.processInfo.environment
        let seed = try #require(UInt64(environment["UP_CANCEL_SEED"] ?? "20261028"))
        let rounds = try #require(Int(environment["UP_CANCEL_ROUNDS"] ?? "1000"))
        try #require(rounds > 0)
        var generator = DelayGenerator(state: seed)
        print("CANCEL STRESS seed=\(seed) mode=\(export ? "export" : "replace") rounds=\(rounds)")
        for round in 0..<rounds {
            let folder = root.appendingPathComponent("round-\(round)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Pin metadata as well as pixels: this test varies cancellation timing, not
            // sub-millisecond filesystem timestamp conversion at a rounding boundary.
            for source in sources {
                var url = folder.appendingPathComponent(source.name)
                try source.data.write(to: url)
                var dates = URLResourceValues()
                dates.creationDate = Date(timeIntervalSince1970: 1_700_000_000)
                dates.contentModificationDate = Date(timeIntervalSince1970: 1_700_000_100)
                try url.setResourceValues(dates)
            }
            let snapshots = try sources.map { source -> Snapshot in
                let url = folder.appendingPathComponent(source.name)
                let image = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
                let decoded = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
                return Snapshot(item: Item(source: url, droppedRoot: nil), bytes: try Data(contentsOf: url),
                                modified: try files.attributes(of: url).modificationDate,
                                created: try files.attributes(of: url).creationDate,
                                width: decoded.width, height: decoded.height,
                                type: CGImageSourceGetType(image) as String? ?? "")
            }
            let outputFolder = root.appendingPathComponent("export-\(round)")
            let destination: Destination = export ? .exportFolder(outputFolder) : .replaceOriginals(moveToTrash: false)
            if export { try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true) }
            let pipeline = Pipeline(fileAccess: files, codec: NativeCodec())
            let queue = Queue(parallelism: 4, pipeline: pipeline.itemPipeline)
            var events = queue.events.makeAsyncIterator()
            var history = QueueEventHistory()
            var terminals: [UUID: Int] = [:]
            await queue.enqueue(Batch(settings: EndToEndTests.q80, outputFormat: .original,
                                      destination: destination, items: snapshots.map(\.item)))
            let delay = generator.next()
            if delay < 2_000 {
                for _ in 0..<delay { await Task.yield() }
            } else { try await Task.sleep(for: .microseconds(delay)) }
            await queue.cancel()
            while let event = await events.next() {
                if case .itemChanged(_, let id, .finished) = event { terminals[id, default: 0] += 1 }
                history.apply(event)
                if event == .idle { break }
            }
            let rows = history.batches.flatMap(\.items)
            let context = "seed=\(seed) round=\(round) mode=\(export ? "export" : "replace") delay=\(delay) outcomes=\(rows.map { "\($0.id):\($0.source.path):\($0.state)" })"
            do {
                try validate(snapshots: snapshots, rows: rows, terminals: terminals, export: export, context: context)
                let reported = rows.compactMap { row -> URL? in
                    switch row.state {
                    case .finished(.optimized(_, _, let output)): output
                    case .finished(.skipped(_, _, let output)): output
                    default: nil
                    }
                }
                let allowed = Set((snapshots.map { $0.item.source } + reported).map { $0.resolvingSymlinksInPath().path })
                let unexpected = try visibleImages(in: root).map { $0.resolvingSymlinksInPath().path }.filter { !allowed.contains($0) }
                #expect(unexpected.isEmpty, "Unreported image: \(unexpected) allowed=\(allowed) \(context)")
                #expect(try leftovers(in: root).isEmpty, "Temporary output: \(context)")
            } catch {
                Issue.record("\(context) error=\(error)")
                throw error
            }
            try FileManager.default.removeItem(at: folder)
            if export { try FileManager.default.removeItem(at: outputFolder) }
        }
    }

    private func validate(snapshots: [Snapshot], rows: [Item], terminals: [UUID: Int], export: Bool, context: String) throws {
        #expect(rows.count == snapshots.count, "Missing/extra rows: \(context)")
        #expect(Set(terminals.keys) == Set(snapshots.map { $0.item.id }), "Terminal identities: \(context)")
        for snapshot in snapshots {
            let matching = rows.filter { $0.id == snapshot.item.id }
            let row = try #require(matching.count == 1 ? matching.first : nil, "Identity: \(context)")
            #expect(row.source == snapshot.item.source && row.sourceIdentity == snapshot.item.sourceIdentity, "Source identity: \(context)")
            #expect(terminals[row.id] == 1, "Terminal count: \(context)")
            let sourceBytes = try Data(contentsOf: snapshot.item.source)
            guard case .finished(let outcome) = row.state else {
                Issue.record("Unfinished row: \(context)"); continue
            }
            var output: URL?
            switch outcome {
            case .failed(let reason): Issue.record("Unexpected failure \(reason): \(context)")
            case .cancelled:
                #expect(sourceBytes == snapshot.bytes, "Cancelled source changed: \(context)")
            case .skipped(let reason, let notes, let url):
                #expect(reason == .alreadyOptimal, "Unexpected skip: \(context)")
                #expect(!export || (url != nil && notes.contains(.copiedUnchanged)), "Missing export copy: \(context)")
                #expect(sourceBytes == snapshot.bytes, "Skipped source changed: \(context)")
                output = url
                if let url { #expect(try Data(contentsOf: url) == snapshot.bytes, "Skipped copy changed: \(context)") }
            case .optimized(let savings, _, let url):
                output = url
                let attributes = try files.attributes(of: url)
                #expect(savings.originalBytes == Int64(snapshot.bytes.count) && savings.newBytes == attributes.size && savings.bytes > 0, "Savings: \(context)")
                let mark = try #require(try files.markedOutput(at: url)?.mark, "Missing mark: \(context)")
                #expect(mark.isValid(for: attributes), "Invalid mark size=\(mark.size)/\(attributes.size) modified=\(mark.modificationDate.timeIntervalSince1970)/\(attributes.modificationDate.timeIntervalSince1970): \(context)")
                #expect(mark.matches(settings: EndToEndTests.q80, outputFormat: snapshot.type == UTType.jpeg.identifier ? .jpeg : .png), "Mark settings: \(context)")
                #expect(export || url == snapshot.item.source, "Replacement path: \(context)")
            }
            if export { #expect(sourceBytes == snapshot.bytes, "Export changed source: \(context)") }
            #expect(try files.attributes(of: snapshot.item.source).modificationDate == snapshot.modified, "Source date: \(context)")
            let url = output ?? snapshot.item.source
            #expect(try files.attributes(of: url).modificationDate == snapshot.modified, "Output date: \(context)")
            #expect(try files.attributes(of: url).creationDate == snapshot.created, "Creation date: \(context)")
            let image = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "Missing output: \(context)")
            #expect(CGImageSourceGetStatus(image) == .statusComplete, "Incomplete image: \(context)")
            let decoded = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil), "Decode: \(context)")
            #expect(decoded.width == snapshot.width && decoded.height == snapshot.height, "Dimensions: \(context)")
            #expect(CGImageSourceGetType(image) as String? == snapshot.type, "Format: \(context)")
        }
    }

    private func allFiles(in folder: URL) throws -> [URL] {
        let enumerator = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        return try #require(enumerator.allObjects as? [URL])
    }

    /// `LocalFileAccess` names temporary files `.<name>.<UUID>.tmp`.
    private func leftovers(in folder: URL) throws -> [URL] {
        try allFiles(in: folder).filter { $0.pathExtension == "tmp" }
    }

    private func visibleImages(in folder: URL) throws -> [URL] {
        try allFiles(in: folder).filter { ["jpg", "png"].contains($0.pathExtension) }
    }

}
