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

/// Injects native encoder failures while keeping the rest of the pipeline and filesystem real.
final class NativeFallbackIntegrationTests {
    private let root: URL
    private let files = LocalFileAccess()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("up-NativeFallbackIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func source(_ name: String, type: UTType, width: Int = 512, height: Int = 384) throws -> URL {
        let url = root.appendingPathComponent(name)
        let image = EndToEndTests.image(width: width, height: height)
        try EndToEndTests.encode(image, as: type).write(to: url)
        return url
    }

    private func exportFolder() throws -> URL {
        let url = root.appendingPathComponent("Export")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(
        source: URL, settings: EffectiveSettings, destination: Destination = .replaceOriginals(moveToTrash: false),
        outputFormat: OutputFormat = .original, failingPath: EncodePath
    ) async -> Outcome {
        let codec = NativeCodec(native: { path, _, _ throws(CodecError) in
            #expect(path == failingPath)
            throw CodecError.encodeFailed("injected native failure")
        })
        let pipeline = Pipeline(fileAccess: files, codec: codec)
        let queue = Queue(parallelism: 1, pixelBudget: .max, pipeline: pipeline.itemPipeline)
        let idle = Task { await QueueEventHistory.collect(untilIdle: queue.events) }
        await queue.enqueue(Batch(
            settings: settings, outputFormat: outputFormat, destination: destination,
            items: [Item(source: source, droppedRoot: nil)]))
        let history = await idle.value
        guard let item = history.batches.first?.items.first,
              case .finished(let outcome) = item.state else { return .cancelled }
        return outcome
    }

    private func mark(at url: URL) throws -> OptimizationMark? {
        try files.markedOutput(at: url)?.mark
    }

    private func rgbaPixels(_ data: Data) throws -> Data {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let didRender = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(didRender)
        return Data(pixels)
    }

    @Test(arguments: [0, 50, 100])
    func coefficientRewriteFailureNeverUsesStoredLossyQuality(_ quality: Int) async throws {
        let url = try source("lossless-\(quality).jpg", type: .jpeg)
        let original = try Data(contentsOf: url)
        let outcome = await run(
            source: url,
            settings: EffectiveSettings(quality: Quality.clamping(quality), lossless: true, resizeRule: .none, keepMetadata: false),
            failingPath: .jpegLosslessRewrite)

        #expect(outcome == .failed(.losslessEncoderUnavailable))
        #expect(try Data(contentsOf: url) == original)
        #expect(try mark(at: url) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [url.lastPathComponent])
    }

    @Test(arguments: [0, 50, 100])
    func visuallyLosslessJPEGFailurePreservesOriginalAndFailsSafely(_ quality: Int) async throws {
        let url = try source("resized-\(quality).jpg", type: .jpeg)
        let original = try Data(contentsOf: url)
        let settings = EffectiveSettings(
            quality: Quality.clamping(quality), lossless: true, resizeRule: .maxLongEdge(128), keepMetadata: false)
        let outcome = await run(
            source: url, settings: settings,
            failingPath: .jpegVisuallyLossless)

        #expect(outcome == .failed(.losslessEncoderUnavailable))
        if case .failed(let reason) = outcome {
            #expect(reason.diagnosticID == "lossless_encoder_unavailable")
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try mark(at: url) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [url.lastPathComponent])
    }

    @Test func failedLosslessJPEGConversionPreservesSourceAndCreatesNoOutput() async throws {
        let url = try source("conversion.png", type: .png)
        let original = try Data(contentsOf: url)
        let outcome = await run(
            source: url,
            settings: EffectiveSettings(quality: 50, lossless: true, resizeRule: .none, keepMetadata: false),
            destination: .exportFolder(try exportFolder()), outputFormat: .jpeg,
            failingPath: .jpegVisuallyLossless)

        #expect(outcome == .failed(.losslessEncoderUnavailable))
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Export").path).isEmpty)
        #expect(try mark(at: url) == nil)
    }

    @Test func lossyJPEGFailureUsesImageIOAndMarksOutput() async throws {
        let url = try source("lossy.jpg", type: .jpeg)
        let original = try Data(contentsOf: url)
        let export = try exportFolder()
        let outcome = await run(
            source: url,
            settings: EffectiveSettings(quality: 60, lossless: false, resizeRule: .none, keepMetadata: false),
            destination: .exportFolder(export), failingPath: .jpegLossy)

        guard case .optimized(_, let notes, let output) = outcome else {
            Issue.record("expected ImageIO lossy fallback to optimize, got \(outcome)")
            return
        }
        #expect(notes.isEmpty)
        #expect(try Data(contentsOf: url) == original)
        let mark = try #require(try mark(at: output))
        #expect(mark.settings == EffectiveSettings(
            quality: 60, lossless: false, resizeRule: .none, keepMetadata: false))
        #expect(mark.isValid(for: try files.attributes(of: output)))
        #expect(mark.outputFormat == .jpeg)
    }

    @Test func pngLosslessFailureUsesEquivalentImageIOFallback() async throws {
        let url = try source("lossless.png", type: .png)
        let original = try Data(contentsOf: url)
        // Make the not-smaller rule deterministic while leaving the PNG image data unchanged.
        try (original + Data(repeating: 0, count: 16_384)).write(to: url)
        let padded = try Data(contentsOf: url)
        let export = try exportFolder()
        let outcome = await run(
            source: url,
            settings: EffectiveSettings(quality: 50, lossless: true, resizeRule: .none, keepMetadata: false),
            destination: .exportFolder(export), failingPath: .pngLossless)

        guard case .optimized(_, let notes, let output) = outcome else {
            Issue.record("expected lossless PNG ImageIO fallback to optimize, got \(outcome)")
            return
        }
        #expect(notes.isEmpty)
        #expect(try Data(contentsOf: url) == padded)
        let mark = try #require(try mark(at: output))
        #expect(mark.settings == EffectiveSettings(
            quality: 50, lossless: true, resizeRule: .none, keepMetadata: false))
        #expect(mark.isValid(for: try files.attributes(of: output)))
        #expect(mark.outputFormat == .png)
        #expect(try rgbaPixels(Data(contentsOf: output)) == rgbaPixels(original))
        let result = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(result) == 1)
    }

    @Test func paletteFailureUsesFullColorImageIOAndReportsTheFallback() async throws {
        let url = try source("palette.png", type: .png)
        let original = try Data(contentsOf: url)
        try (original + Data(repeating: 0, count: 16_384)).write(to: url)
        let padded = try Data(contentsOf: url)
        let export = try exportFolder()
        let outcome = await run(
            source: url,
            settings: EffectiveSettings(quality: 50, lossless: false, resizeRule: .none, keepMetadata: false),
            destination: .exportFolder(export), failingPath: .pngPalette)

        guard case .optimized(_, let notes, let output) = outcome else {
            Issue.record("expected palette fallback to optimize, got \(outcome)")
            return
        }
        #expect(notes == [.keptFullColor])
        #expect(try Data(contentsOf: url) == padded)
        let mark = try #require(try mark(at: output))
        #expect(mark.settings == EffectiveSettings(
            quality: 50, lossless: false, resizeRule: .none, keepMetadata: false))
        #expect(mark.isValid(for: try files.attributes(of: output)))
        #expect(mark.outputFormat == .png)
        #expect(try rgbaPixels(Data(contentsOf: output)) == rgbaPixels(original))
        let result = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(result) == 1)
    }
}
