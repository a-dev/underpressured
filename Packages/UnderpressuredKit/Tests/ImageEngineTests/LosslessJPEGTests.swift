import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UnderpressuredCore
@testable import ImageEngine

/// 4.3: the lossless rewrite keeps the DCT coefficients. Compared as coefficients, never as
/// ImageIO decodes (0.12: two decoders may round differently on the same coefficients).
@Suite struct LosslessJPEGTests {
    static let corpus = URL(filePath: #filePath)
        .deletingLastPathComponent().appending(path: "../../../../bench/corpus").standardized

    static var corpusJPEGs: [URL] {
        let files = FileManager.default.enumerator(at: corpus, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        return files.filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
    }

    static let fixtures: [(String, @Sendable () throws -> Data)] = [
        ("rgb", { try ImageFixtures.rgbJPEG() }),
        ("gray", { try ImageFixtures.grayscaleJPEG() }),
        ("cmyk", { try ImageFixtures.cmykJPEG() }),
        ("displayP3", { try ImageFixtures.displayP3JPEG() }),
        ("orientation6", { try ImageFixtures.jpeg(orientation: 6) }),
        ("allMetadata", { try ImageFixtures.jpegWithAllMetadata() }),
        ("gainMap", { try ImageFixtures.jpegWithGainMap() }),
    ]

    private func rewrite(_ data: Data, keepMetadata: Bool = true) async throws -> EncodedImage {
        let codec = NativeCodec()
        let image = try await codec.decode(data)
        return try await codec.encode(image, EncodePlan(format: .jpeg, quality: 80, lossless: true, keepMetadata: keepMetadata))
    }

    @Test(arguments: fixtures.map(\.0))
    func fixtureCoefficientsAreIdentical(_ name: String) async throws {
        let source = try #require(Self.fixtures.first { $0.0 == name }).1()
        for keep in [true, false] {
            let output = try await rewrite(source, keepMetadata: keep)
            #expect(try Jpegli.coefficientsEqual(source, output.data))
        }
    }

    @Test(.enabled(if: !corpusJPEGs.isEmpty, "bench/corpus not downloaded"))
    func corpusCoefficientsAreIdentical() async throws {
        for url in Self.corpusJPEGs {
            let source = try Data(contentsOf: url)
            let output = try await rewrite(source)
            #expect(try Jpegli.coefficientsEqual(source, output.data), "\(url.lastPathComponent)")
            #expect(output.data.count < source.count, "\(url.lastPathComponent)")
        }
    }

    @Test func outputIsProgressiveWithICC() async throws {
        let source = try ImageFixtures.displayP3JPEG()
        let output = try await rewrite(source, keepMetadata: false)
        let props = try properties(output.data)
        let jfif = props[kCGImagePropertyJFIFDictionary] as? [CFString: Any]
        #expect(jfif?[kCGImagePropertyJFIFIsProgressive] as? Bool == true)
        #expect(props[kCGImagePropertyProfileName] as? String == "Display P3")
    }

    @Test func orientationTagStaysWithoutKeepMetadata() async throws {
        let source = try ImageFixtures.jpeg(orientation: 6, width: 40, height: 20)
        let output = try await rewrite(source, keepMetadata: false)
        #expect(try properties(output.data)[kCGImagePropertyOrientation] as? Int == 6)
        #expect(output.pixelWidth == 20)
        #expect(output.pixelHeight == 40)
    }

    @Test func metadataFollowsKeepMetadata() async throws {
        let source = try ImageFixtures.jpegWithAllMetadata()
        let kept = try properties(try await rewrite(source, keepMetadata: true).data)
        let stripped = try properties(try await rewrite(source, keepMetadata: false).data)
        #expect(kept[kCGImagePropertyGPSDictionary] != nil)
        #expect(kept[kCGImagePropertyIPTCDictionary] != nil)
        #expect(stripped[kCGImagePropertyGPSDictionary] == nil)
        #expect(stripped[kCGImagePropertyIPTCDictionary] == nil)
    }

    @Test func gainMapIsRemovedWithNote() async throws {
        let source = try ImageFixtures.jpegWithGainMap()
        let output = try await rewrite(source)
        #expect(output.notes.contains(.hdrRemoved))
        let src = try #require(CGImageSourceCreateWithData(output.data as CFData, nil))
        #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) == nil)
    }

    @Test func resizedImageIsNotRewritten() async throws {
        let codec = NativeCodec()
        var image = try await codec.decode(try ImageFixtures.rgbJPEG())
        #expect(EncodePath.select(EncodePlan(format: .jpeg, quality: 80, lossless: true, keepMetadata: true), image)
            == .jpegLosslessRewrite)
        image = try await codec.transform(image, TransformPlan(resizeRule: .maxLongEdge(32), flattenOntoWhite: false))
        #expect(image.pixelsTransformed)
        #expect(EncodePath.select(EncodePlan(format: .jpeg, quality: 80, lossless: true, keepMetadata: true), image)
            == .jpegVisuallyLossless)
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }
}
