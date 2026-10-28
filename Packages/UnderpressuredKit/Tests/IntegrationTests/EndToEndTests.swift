import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import QueueTestSupport
import UnderpressuredCore

@testable import ImageEngine
@testable import LocalFileSystem

/// Real Queue + Pipeline + LocalFileAccess + ImageIOCodec in temporary folders (plan 3.9, 3.12).
final class EndToEndTests {
    let root: URL
    let files = LocalFileAccess()

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("up-EndToEndTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    static let q80 = EffectiveSettings(quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)
    static let q60 = EffectiveSettings(quality: 60, lossless: false, resizeRule: .none, keepMetadata: false)

    // MARK: Helpers

    /// Noisy-but-compressible RGB pixels: a smooth gradient plus small deterministic noise.
    static func image(width: Int, height: Int, alpha: Bool = false, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        let stride = context.bytesPerRow
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var state = seed
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let noise = Int((state >> 59) & 0xF) - 8
                let offset = y * stride + x * 4
                func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }
                pixels[offset] = clamp(x * 255 / width + noise)
                pixels[offset + 1] = clamp(y * 255 / height + noise)
                pixels[offset + 2] = clamp((x + y) * 255 / (width + height) + noise)
                pixels[offset + 3] = 255
            }
        }
        return context.makeImage()!
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double = 1.0) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @discardableResult
    func makeFile(
        _ path: String, type: UTType = .jpeg, width: Int = 1200, height: Int = 800,
        modified: Date = Date(timeIntervalSince1970: 1_600_000_000), tags: [String] = [],
        seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    ) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(Self.image(width: width, height: height, seed: seed), as: type).write(to: url)
        var values = URLResourceValues()
        if !tags.isEmpty {
            values.tagNames = tags
            var mutable = url
            try mutable.setResourceValues(values)
        }
        var dates = URLResourceValues()
        dates.creationDate = modified.addingTimeInterval(-86_400)
        dates.contentModificationDate = modified
        var mutable = url
        try mutable.setResourceValues(dates)
        return url
    }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs one Batch through a real Queue and returns the Outcomes in Item order.
    @discardableResult
    func run(
        _ sources: [URL], droppedRoot: URL? = nil, settings: EffectiveSettings = EndToEndTests.q80,
        format: OutputFormat = .original, destination: Destination, fileAccess: LocalFileAccess? = nil
    ) async -> [Outcome] {
        let pipeline = Pipeline(fileAccess: fileAccess ?? files, codec: NativeCodec())
        let queue = Queue(parallelism: 2, pixelBudget: .max, pipeline: pipeline.itemPipeline)
        let idle = Task { await QueueEventHistory.collect(untilIdle: queue.events) }
        await queue.enqueue(
            Batch(
                settings: settings, outputFormat: format, destination: destination,
                items: sources.map { Item(source: $0, droppedRoot: droppedRoot) }))
        let history = await idle.value
        let items = history.batches.first?.items ?? []
        return items.map { item in
            guard case .finished(let outcome) = item.state else { return .cancelled }
            return outcome
        }
    }

    func mark(at url: URL) throws -> OptimizationMark? {
        try files.markedOutput(at: url)?.mark
    }

    func size(_ url: URL) throws -> Int64 { try files.attributes(of: url).size }

    /// Format and pixel size as ImageIO sees the file.
    func properties(_ url: URL) throws -> (type: String, width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (
            CGImageSourceGetType(source) as String? ?? "",
            props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0
        )
    }

    func relativePaths() -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).sorted()
    }

    /// No hidden file or temporary leftover anywhere under the root.
    func expectNoHiddenFiles() {
        let hidden = relativePaths().filter { $0.split(separator: "/").contains { $0.hasPrefix(".") } }
        #expect(hidden.isEmpty, "leftover hidden files: \(hidden)")
    }

    func expectOptimized(_ outcome: Outcome, notes: [Note] = []) -> Savings? {
        guard case .optimized(let savings, let actual, _) = outcome else {
            Issue.record("expected optimized, got \(outcome)")
            return nil
        }
        #expect(actual == notes)
        return savings
    }

    // MARK: Replace originals

    @Test func replaceSameFormat_done1_replacesInPlaceSmallerKeepingDatesAndTags() async throws {
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let source = try makeFile("photos/a.jpg", modified: date, tags: ["Red"])
        let before = try files.attributes(of: source)

        let outcomes = await run([source], destination: .replaceOriginals(moveToTrash: false))

        let savings = try #require(expectOptimized(outcomes[0]))
        let after = try files.attributes(of: source)
        #expect(after.size < before.size)
        #expect(savings.originalBytes == before.size && savings.newBytes == after.size)
        let props = try properties(source)
        #expect(props.type == UTType.jpeg.identifier && props.width == 1200 && props.height == 800)
        let valid = try #require(try mark(at: source))
        #expect(valid.isValid(for: after))
        #expect(valid.settings == Self.q80 && valid.outputFormat == .jpeg)
        #expect(abs(after.modificationDate.timeIntervalSince(date)) < 0.01)
        #expect(abs(after.creationDate.timeIntervalSince(date.addingTimeInterval(-86_400))) < 0.01)
        #expect(try source.resourceValues(forKeys: [.tagNamesKey]).tagNames == ["Red"])
        #expect(relativePaths() == ["photos", "photos/a.jpg"])
        expectNoHiddenFiles()
    }

    @Test func replaceReadOnlyOriginal_spec8_keepsItsPermissionsAndGetsTheMark() async throws {
        let source = try makeFile("photos/a.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: source.path)

        let outcomes = await run([source], destination: .replaceOriginals(moveToTrash: false))

        _ = try #require(expectOptimized(outcomes[0]))
        let mode = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int
        #expect(mode == 0o400)
        #expect(try mark(at: source) != nil)
        expectNoHiddenFiles()
    }

    @Test func replaceWithFormatChange_done1_newFileWrittenAndSourceRemoved() async throws {
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let source = try makeFile("photos/shot.png", type: .png, width: 800, height: 600, modified: date, tags: ["Blue"])
        let originalSize = try size(source)

        let outcomes = await run([source], format: .jpeg, destination: .replaceOriginals(moveToTrash: false))

        let savings = try #require(expectOptimized(outcomes[0]))
        #expect(savings.originalBytes == originalSize)
        let result = root.appendingPathComponent("photos/shot.jpg")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try size(result) < originalSize)
        let props = try properties(result)
        #expect(props.type == UTType.jpeg.identifier && props.width == 800 && props.height == 600)
        let attributes = try files.attributes(of: result)
        let valid = try #require(try mark(at: result))
        #expect(valid.isValid(for: attributes) && valid.outputFormat == .jpeg)
        #expect(abs(attributes.modificationDate.timeIntervalSince(date)) < 0.01)
        #expect(try result.resourceValues(forKeys: [.tagNamesKey]).tagNames == ["Blue"])
        #expect(relativePaths() == ["photos", "photos/shot.jpg"])
        expectNoHiddenFiles()
    }

    @Test(arguments: [false, true])
    func replaceWithTrash_preservesRecoverableOriginal(converting: Bool) async throws {
        let captured = OwnedTrashItems()
        defer { captured.cleanup() }
        let access = LocalFileAccess(trashOperation: { source in
            try captured.capture { try LocalFileAccess.foundationTrash(source) }
        })
        let name = UUID().uuidString
        let source = try makeFile("photos/\(name).\(converting ? "png" : "jpg")",
                                  type: converting ? .png : .jpeg,
                                  seed: UInt64(name.prefix(8), radix: 16)!)
        let original = try Data(contentsOf: source)
        try #require(access.hasTrash(forItemAt: source), "Real volume Trash is required")
        let outcomes = await run([source], format: converting ? .jpeg : .original,
                                 destination: .replaceOriginals(moveToTrash: true), fileAccess: access)
        #expect(outcomes.count == 1)
        let outcome = try #require(outcomes.first)
        _ = try #require(expectOptimized(outcome))
        let trashed = try #require(captured.urls.count == 1 ? captured.urls.first : nil)
        #expect(try Data(contentsOf: trashed) == original)
        let output = source.deletingPathExtension().appendingPathExtension("jpg")
        #expect(try Data(contentsOf: output) != original)
        let props = try properties(output)
        #expect(props.type == UTType.jpeg.identifier && props.width == 1200 && props.height == 800)
        let imageSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil)
        let valid = try #require(try mark(at: output))
        #expect(valid.isValid(for: try files.attributes(of: output)))
        if converting { #expect(!files.fileExists(at: source)) }
        expectNoHiddenFiles()
    }

    @Test func replaceTwiceWithSameSettings_done2_secondIsSkippedAlreadyOptimized() async throws {
        let source = try makeFile("photos/a.jpg")
        let first = await run([source], destination: .replaceOriginals(moveToTrash: false))
        _ = try #require(expectOptimized(first[0]))
        let afterFirst = try Data(contentsOf: source)

        let second = await run([source], destination: .replaceOriginals(moveToTrash: false))

        #expect(second == [.skipped(.alreadyOptimized, notes: [])])
        #expect(try Data(contentsOf: source) == afterFirst)
        expectNoHiddenFiles()
    }

    // MARK: Export

    @Test func exportMirroring_done2_writesUnderRootAndSubfolderLeavingSourcesUntouched() async throws {
        let dropped = try folder("Trip")
        let top = try makeFile("Trip/top.jpg")
        let nested = try makeFile("Trip/day1/nested.jpg")
        let loose = try makeFile("loose.jpg")
        let export = try folder("Export")
        let originals = [try size(top), try size(nested), try size(loose)]

        let outcomes = await run(
            [top, nested], droppedRoot: dropped, destination: .exportFolder(export))
        let looseOutcomes = await run([loose], destination: .exportFolder(export))

        for outcome in outcomes + looseOutcomes { _ = try #require(expectOptimized(outcome)) }
        let results = [
            export.appendingPathComponent("Trip/top.jpg"),
            export.appendingPathComponent("Trip/day1/nested.jpg"),
            export.appendingPathComponent("loose.jpg"),
        ]
        for (index, url) in results.enumerated() {
            #expect(try size(url) < originals[index])
            let valid = try #require(try mark(at: url))
            #expect(valid.isValid(for: try files.attributes(of: url)))
            #expect(try properties(url).type == UTType.jpeg.identifier)
        }
        #expect(try size(top) == originals[0] && (try mark(at: top)) == nil)
        #expect(try size(nested) == originals[1])
        #expect(try mark(at: nested) == nil)
        expectNoHiddenFiles()
    }

    @Test func exportMirroring_scannedNestedFolder_keepsTheTree() async throws {
        let dropped = try folder("Trip")
        try makeFile("Trip/top.jpg")
        try makeFile("Trip/day1/a.png", type: .png)
        try makeFile("Trip/day1/evening/b.jpg")
        let export = try folder("Export")

        let scan = Scanner(files: files).scan([dropped], exportFolder: export, isActive: { _ in false })
        let pipeline = Pipeline(fileAccess: files, codec: NativeCodec())
        let queue = Queue(parallelism: 2, pixelBudget: .max, pipeline: pipeline.itemPipeline)
        let idle = Task { await QueueEventHistory.collect(untilIdle: queue.events) }
        await queue.enqueue(
            Batch(settings: Self.q80, outputFormat: .original, destination: .exportFolder(export), items: scan.items))
        _ = await idle.value

        let exported = relativePaths().filter { $0.hasPrefix("Export/") && $0.contains(".") }
        #expect(exported == ["Export/Trip/day1/a.png", "Export/Trip/day1/evening/b.jpg", "Export/Trip/top.jpg"])
    }

    @Test func exportNameClash_done2_unmarkedExistingFileIsKeptAndTheResultIsNumbered() async throws {
        let dropped = try folder("Trip")
        let source = try makeFile("Trip/a.jpg")
        let export = try folder("Export")
        let existing = export.appendingPathComponent("Trip/a.jpg")
        try FileManager.default.createDirectory(
            at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theirs = Data("someone else's file".utf8)
        try theirs.write(to: existing)

        let outcomes = await run([source], droppedRoot: dropped, destination: .exportFolder(export))

        _ = try #require(expectOptimized(outcomes[0]))
        #expect(try Data(contentsOf: existing) == theirs)
        let numbered = export.appendingPathComponent("Trip/a-2.jpg")
        #expect(try properties(numbered).type == UTType.jpeg.identifier)
        #expect(try mark(at: numbered) != nil)
        #expect(try mark(at: existing) == nil)
        expectNoHiddenFiles()
    }

    @Test func reExportWithOtherQuality_done2_refreshesMarkedFileWithoutNumberedCopy() async throws {
        let dropped = try folder("Trip")
        let source = try makeFile("Trip/a.jpg")
        let export = try folder("Export")
        let target = export.appendingPathComponent("Trip/a.jpg")

        let first = await run(
            [source], droppedRoot: dropped, settings: Self.q80, destination: .exportFolder(export))
        _ = try #require(expectOptimized(first[0]))
        let firstSize = try size(target)

        let second = await run(
            [source], droppedRoot: dropped, settings: Self.q60, destination: .exportFolder(export))

        _ = try #require(expectOptimized(second[0]))
        #expect(try size(target) < firstSize, "quality 60 output replaced the quality 80 one")
        #expect(try mark(at: target)?.settings == Self.q60)
        let names = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        #expect(names == ["a.jpg"])
        expectNoHiddenFiles()
    }

    // MARK: 3.9 Export specifics

    @Test func exportAlreadyOptimizedSource_3_9_isCopiedUnchangedWithNoteAndFreshMark() async throws {
        let dropped = try folder("Trip")
        let source = try makeFile("Trip/a.jpg", tags: ["Green"])
        let export = try folder("Export")
        // Optimize the source in place first, so it carries a valid mark for these settings.
        let replaced = await run([source], settings: Self.q80, destination: .replaceOriginals(moveToTrash: false))
        _ = try #require(expectOptimized(replaced[0]))
        let sourceBytes = try Data(contentsOf: source)

        let outcomes = await run(
            [source], droppedRoot: dropped, settings: Self.q80, destination: .exportFolder(export))

        let copy = export.appendingPathComponent("Trip/a.jpg")
        #expect(outcomes == [.skipped(.alreadyOptimized, notes: [.copiedUnchanged], output: copy)])
        #expect(try Data(contentsOf: copy) == sourceBytes)
        let valid = try #require(try mark(at: copy))
        #expect(valid.isValid(for: try files.attributes(of: copy)))
        #expect(valid.settings == Self.q80 && valid.outputFormat == .jpeg)
        #expect(try copy.resourceValues(forKeys: [.tagNamesKey]).tagNames == ["Green"])
        #expect(try Data(contentsOf: source) == sourceBytes)
        expectNoHiddenFiles()
    }

    @Test func exportAlreadyOptimalSource_3_9_isCopiedUnchangedWithNote() async throws {
        // A JPEG already encoded at Quality 80: re-encoding it can't make it smaller.
        let dropped = try folder("Trip")
        let url = root.appendingPathComponent("Trip/small.jpg")
        let image = Self.image(width: 200, height: 150)
        try Self.encode(image, as: .jpeg, quality: 0.3).write(to: url)
        let export = try folder("Export")

        let outcomes = await run([url], droppedRoot: dropped, destination: .exportFolder(export))

        let copy = export.appendingPathComponent("Trip/small.jpg")
        #expect(outcomes == [.skipped(.alreadyOptimal, notes: [.copiedUnchanged], output: copy)])
        #expect(try Data(contentsOf: copy) == Data(contentsOf: url))
        #expect(try mark(at: copy) != nil)
        expectNoHiddenFiles()
    }

    @Test func exportFolderMissing_3_9_failsEveryItemOfTheBatch() async throws {
        let dropped = try folder("Trip")
        let a = try makeFile("Trip/a.jpg")
        let b = try makeFile("Trip/day1/b.jpg")
        let missing = root.appendingPathComponent("NoSuchExport")
        let before = relativePaths()

        let outcomes = await run([a, b], droppedRoot: dropped, destination: .exportFolder(missing))

        #expect(outcomes == [.failed(.exportFolderUnavailable), .failed(.exportFolderUnavailable)])
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(relativePaths() == before)
    }

    // MARK: Resize

    @Test func resizeNote_done1_maxLongEdgeResizesBigImageAndSaysSo() async throws {
        let source = try makeFile("photos/big.jpg", width: 3000, height: 2000)
        let settings = EffectiveSettings(quality: 80, lossless: false, resizeRule: .maxLongEdge(1000), keepMetadata: false)

        let outcomes = await run([source], settings: settings, destination: .replaceOriginals(moveToTrash: false))

        _ = try #require(expectOptimized(outcomes[0], notes: [.resized(from: 3000, to: 1000)]))
        let props = try properties(source)
        #expect(props.width == 1000 && props.height == 667)
        expectNoHiddenFiles()
    }
}
