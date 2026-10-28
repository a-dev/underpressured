import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import Testing
import Synchronization
import UnderpressuredCore
@testable import ImageEngine

/// 4.1 / 4.2: jpegli lossy and visually lossless encodes. Direct `JPEGEncode` calls prove the
/// native path ran (NativeCodec would silently fall back to ImageIO).
@Suite struct JPEGEncodeTests {
    @Test(arguments: [true, false])
    func nativeLosslessConversionAndResize(jpegSource: Bool) async throws {
        let codec = NativeCodec()
        let data = jpegSource ? try ImageFixtures.rgbJPEG() : try ImageFixtures.rgbaPNG()
        let decoded = try await codec.decode(data)
        let transformed = try await codec.transform(decoded, TransformPlan(
            resizeRule: jpegSource ? .maxLongEdge(32) : .none, flattenOntoWhite: true))
        let low = try await codec.encode(transformed, plan(quality: 0, lossless: true))
        let high = try await codec.encode(transformed, plan(quality: 100, lossless: true))
        #expect(low.data == high.data)
        #expect(low.notes.contains(.reencodedVisuallyLossless))
        let source = try #require(CGImageSourceCreateWithData(low.data as CFData, nil))
        let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(!Redraw.hasAlpha(pixels))
        #expect(pixels.width == transformed.pixels.width && pixels.height == transformed.pixels.height)
        if jpegSource {
            #expect(max(pixels.width, pixels.height) == 32)
        } else {
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = try #require(CGContext(data: &rgba, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixels, in: CGRect(x: -(pixels.width - 2), y: -2, width: pixels.width, height: pixels.height))
            #expect(rgba[0] > 240 && rgba[1] > 240 && rgba[2] > 240)
        }
    }

    @Test(arguments: [true, false], [0, 100])
    func visuallyLosslessRequestsLiteralDistance(jpegSource: Bool, quality: Int) async throws {
        let distances = Mutex<[Float]>([])
        let codec = NativeCodec(native: { path, image, plan throws(CodecError) in
            guard path == .jpegVisuallyLossless else {
                Issue.record("Expected visually lossless re-encode, got \(path)")
                return try NativeCodec.encode(path, image, plan)
            }
            return try JPEGEncode.visuallyLossless(image, plan, encoder: {
                pixels, width, height, stride, components, distance, progressive, icc throws(JpegliError) in
                distances.withLock { $0.append(distance) }
                return try Jpegli.encode(
                    pixels: pixels, width: width, height: height, bytesPerRow: stride,
                    components: components, distance: distance, progressive: progressive, iccProfile: icc)
            })
        })
        let decoded = try await codec.decode(JPEGFidelityFixture.data(jpeg: jpegSource))
        let image = try await codec.transform(decoded, TransformPlan(
            resizeRule: jpegSource ? .maxLongEdge(128) : .none, flattenOntoWhite: true))
        _ = try await codec.encode(image, plan(quality: quality, lossless: true))
        #expect(distances.withLock { $0 } == [1.0])
    }

    @Test(arguments: [true, false])
    func nativeVisuallyLosslessPreservesDetailedPixels(jpegSource: Bool) async throws {
        let codec = NativeCodec()
        let decoded = try await codec.decode(JPEGFidelityFixture.data(jpeg: jpegSource))
        #expect(decoded.pixels.width == 256 && decoded.pixels.height == 192)
        let image = try await codec.transform(decoded, TransformPlan(
            resizeRule: jpegSource ? .maxLongEdge(128) : .none, flattenOntoWhite: true))
        let width = jpegSource ? 128 : 256
        let height = jpegSource ? 96 : 192
        #expect(image.pixels.width == width && image.pixels.height == height)
        let reference = try fidelityRGB(image.pixels)
        try #require(reference.min()! < 40 && reference.max()! > 215)
        try #require(Set(reference).count > 180)
        let edgeCount = zip(reference.dropFirst(3), reference).filter { abs(Int($0) - Int($1)) > 15 }.count
        try #require(edgeCount > width * height / 10)

        // Fixture-specific bounds and calibration evidence: Fixtures/JPEGFidelityFixture.swift.
        let floor = jpegSource ? 55.0 : 70.0
        for quality in [0, 100] {
            let stripped = try await codec.encode(image, plan(quality: quality, lossless: true))
            let kept = try await codec.encode(image, plan(quality: quality, lossless: true, keep: true))
            #expect(stripped.notes.contains(.reencodedVisuallyLossless))
            #expect(stripped.format == .jpeg)
            #expect(stripped.pixelWidth == width && stripped.pixelHeight == height)
            #expect(try isProgressive(stripped.data))
            let score = try fidelityScore(stripped.data, reference: reference, width: width, height: height)
            let keptScore = try fidelityScore(kept.data, reference: reference, width: width, height: height)
            print("JPEG fidelity jpegSource=\(jpegSource) distance1=\(score)")
            #expect(score > floor, "SSIMULACRA2 \(score), JPEG source: \(jpegSource)")
            #expect(abs(score - keptScore) < 0.001)
            #expect(try Jpegli.coefficientsEqual(stripped.data, kept.data))
            #expect(try group(kept.data, kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFMake as String]
                as? String == "JPEG fidelity fixture")
            #expect(try group(stripped.data, kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFMake as String] == nil)
        }

        // Calibrate the adversarial control through jpegli directly, outside production path selection.
        let coarse = try reference.withUnsafeBytes {
            try Jpegli.encode(pixels: $0, width: width, height: height, bytesPerRow: width * 3,
                components: .rgb, distance: 10.0, progressive: true, iccProfile: nil)
        }
        let coarseScore = try fidelityScore(coarse, reference: reference, width: width, height: height)
        #expect(coarseScore < (jpegSource ? 45 : 60), "distance-10 SSIMULACRA2 \(coarseScore)")
        let blank = [UInt8](repeating: 127, count: reference.count)
        let wrong = try blank.withUnsafeBytes {
            try Jpegli.encode(pixels: $0, width: width, height: height, bytesPerRow: width * 3,
                components: .rgb, distance: 1.0, progressive: true, iccProfile: nil)
        }
        #expect(try fidelityScore(wrong, reference: reference, width: width, height: height) < floor)
        print("JPEG fidelity jpegSource=\(jpegSource) distance10=\(coarseScore)")
    }

    /// Test-side sRGB rendering; does not use PixelBuffer or production quality scoring.
    private func fidelityRGB(_ image: CGImage) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return rgba.enumerated().compactMap { $0.offset % 4 == 3 ? nil : $0.element }
    }

    private func fidelityScore(_ data: Data, reference: [UInt8], width: Int, height: Int) throws -> Double {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        try #require(pixels.width == width && pixels.height == height)
        let candidate = try fidelityRGB(pixels)
        return try reference.withUnsafeBytes { referenceBytes in
            try candidate.withUnsafeBytes { candidateBytes in
                try Jpegli.ssimulacra2(reference: referenceBytes, distorted: candidateBytes,
                    width: width, height: height, bytesPerRow: width * 3, components: .rgb)
            }
        }
    }

    private func plan(quality: Int = 75, lossless: Bool = false, keep: Bool = false) -> EncodePlan {
        EncodePlan(format: .jpeg, quality: Quality.clamping(quality), lossless: lossless, keepMetadata: keep)
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func isProgressive(_ data: Data) throws -> Bool {
        let jfif = try properties(data)[kCGImagePropertyJFIFDictionary] as? [CFString: Any]
        return jfif?[kCGImagePropertyJFIFIsProgressive] as? Bool == true
    }

    private func group(_ data: Data, _ key: CFString) throws -> [String: Any]? {
        try properties(data)[key] as? [String: Any]
    }

    @Test func lossy_spec7_4_isProgressiveJPEGWithDimensions() throws {
        let image = try Decode.decode(ImageFixtures.rgbJPEG(width: 96, height: 64))
        let out = try JPEGEncode.lossy(image, plan())
        #expect(out.format == .jpeg)
        #expect(out.pixelWidth == 96 && out.pixelHeight == 64)
        #expect(try isProgressive(out.data))
        #expect(out.notes.isEmpty)
        let props = try properties(out.data)
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 96)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 64)
    }

    @Test func lossy_spec7_4_qualityIsPassedThrough() throws {
        let image = try Decode.decode(ImageFixtures.rgbJPEG())
        let low = try JPEGEncode.lossy(image, plan(quality: 30))
        let high = try JPEGEncode.lossy(image, plan(quality: 95))
        #expect(low.data.count < high.data.count)
    }

    @Test func lossy_spec7_3_embedsICCProfile() throws {
        let image = try Decode.decode(ImageFixtures.displayP3JPEG())
        for keep in [true, false] {
            let out = try JPEGEncode.lossy(image, plan(keep: keep))
            #expect(try properties(out.data)[kCGImagePropertyProfileName] as? String == "Display P3")
        }
    }

    @Test func lossy_spec7_4_grayStaysGray() throws {
        let image = try Decode.decode(ImageFixtures.grayscaleJPEG())
        let out = try JPEGEncode.lossy(image, plan())
        #expect(try properties(out.data)[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelGray as String)
        #expect(try isProgressive(out.data))
    }

    @Test func lossy_spec7_4_cmykBecomesSRGB() throws {
        let image = try Decode.decode(ImageFixtures.cmykJPEG())
        let out = try JPEGEncode.lossy(image, plan())
        #expect(try properties(out.data)[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelRGB as String)
        #expect(out.pixelWidth == image.pixels.width)
    }

    @Test func lossy_spec7_4_sixteenBitAndAlphaBecome8BitRGB() throws {
        for data in [try ImageFixtures.png16(), try ImageFixtures.rgbaPNG()] {
            let image = try Decode.decode(data)
            let out = try JPEGEncode.lossy(image, plan())
            let props = try properties(out.data)
            #expect(props[kCGImagePropertyDepth] as? Int == 8)
            #expect(props[kCGImagePropertyHasAlpha] as? Bool != true)
        }
    }

    @Test func lossy_spec7_3_keepOffStripsMetadata() throws {
        let image = try Decode.decode(ImageFixtures.jpegWithAllMetadata())
        let out = try JPEGEncode.lossy(image, plan(keep: false))
        #expect(try group(out.data, kCGImagePropertyGPSDictionary) == nil)
        #expect(try group(out.data, kCGImagePropertyIPTCDictionary) == nil)
        #expect(try group(out.data, kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFMake as String] == nil)
        #expect(try group(out.data, kCGImagePropertyExifDictionary)?[kCGImagePropertyExifUserComment as String] == nil)
        #expect(try properties(out.data)[kCGImagePropertyProfileName] != nil)
    }

    @Test func lossy_spec7_3_keepOnWritesMetadataWithoutRecompressing() throws {
        let image = try Decode.decode(ImageFixtures.jpegWithAllMetadata())
        let stripped = try JPEGEncode.lossy(image, plan(keep: false))
        let kept = try JPEGEncode.lossy(image, plan(keep: true))
        let exif = try #require(try group(kept.data, kCGImagePropertyExifDictionary))
        #expect(exif[kCGImagePropertyExifUserComment as String] as? String == ImageFixtures.Metadata.exifUserComment)
        let tiff = try #require(try group(kept.data, kCGImagePropertyTIFFDictionary))
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == ImageFixtures.Metadata.cameraMake)
        let gps = try #require(try group(kept.data, kCGImagePropertyGPSDictionary))
        #expect(abs((gps[kCGImagePropertyGPSLatitude as String] as? Double ?? 0) - ImageFixtures.Metadata.gpsLatitude) < 0.001)
        let iptc = try #require(try group(kept.data, kCGImagePropertyIPTCDictionary))
        #expect(iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String == ImageFixtures.Metadata.iptcCaption)
        let source = try #require(CGImageSourceCreateWithData(kept.data as CFData, nil))
        let xmp = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        let creator = try #require(CGImageMetadataCopyTagWithPath(xmp, nil, "dc:creator[0]" as CFString))
        #expect(CGImageMetadataTagCopyValue(creator) as? String == ImageFixtures.Metadata.xmpCreator)

        #expect(try isProgressive(kept.data))
        #expect(try Jpegli.coefficientsEqual(stripped.data, kept.data))
        #expect(try properties(kept.data)[kCGImagePropertyProfileName] as? String
            == properties(stripped.data)[kCGImagePropertyProfileName] as? String)
    }

    @Test func lossy_spec7_3_keepOnKeepsICC() throws {
        let image = try Decode.decode(ImageFixtures.displayP3JPEG())
        let out = try JPEGEncode.lossy(image, plan(keep: true))
        #expect(try properties(out.data)[kCGImagePropertyProfileName] as? String == "Display P3")
        #expect(try isProgressive(out.data))
    }

    @Test func lossy_spec7_3_keepOnResetsOrientation() throws {
        var image = try Decode.decode(ImageFixtures.jpegWithAllMetadata())
        image.metadata.properties[kCGImagePropertyOrientation] = 6
        var tiff = image.metadata.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 6
        image.metadata.properties[kCGImagePropertyTIFFDictionary] = tiff
        let out = try JPEGEncode.lossy(image, plan(keep: true))
        let props = try properties(out.data)
        #expect((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect((try group(out.data, kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFOrientation as String] as? Int ?? 1) == 1)
    }

    @Test(arguments: [true, false])
    func lossy_spec7_3_gainMapIsDroppedWithNote(keep: Bool) throws {
        let image = try Decode.decode(ImageFixtures.jpegWithGainMap())
        let out = try JPEGEncode.lossy(image, plan(keep: keep))
        #expect(out.notes == [.hdrRemoved])
        let source = try #require(CGImageSourceCreateWithData(out.data as CFData, nil))
        #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) == nil)
    }

    @Test func nativeCodecRunsJpegliForLossyAndKeepsSourceNotes() async throws {
        let codec = NativeCodec()
        let image = try await codec.decode(ImageFixtures.rgbPNG())
        let out = try await codec.encode(image, plan(quality: 40))
        let direct = try JPEGEncode.lossy(image, plan(quality: 40))
        #expect(out.data == direct.data)
    }

    // MARK: 4.2

    @Test func visuallyLossless_spec7_4_setsNoteAndIsProgressive() throws {
        let image = try Decode.decode(ImageFixtures.rgbPNG())
        let out = try JPEGEncode.visuallyLossless(image, plan(lossless: true))
        #expect(out.notes == [.reencodedVisuallyLossless])
        #expect(out.format == .jpeg)
        #expect(try isProgressive(out.data))
        #expect(out.pixelWidth == image.pixels.width && out.pixelHeight == image.pixels.height)
    }

    @Test func visuallyLossless_spec7_4_isReachedForResizedJPEG() async throws {
        let codec = NativeCodec()
        let decoded = try await codec.decode(ImageFixtures.displayP3JPEG())
        let image = try await codec.transform(decoded, TransformPlan(resizeRule: .maxLongEdge(48), flattenOntoWhite: true))
        let out = try await codec.encode(image, plan(lossless: true))
        #expect(out.notes.contains(.reencodedVisuallyLossless))
        #expect(out.pixelWidth <= 48)
        #expect(try properties(out.data)[kCGImagePropertyProfileName] as? String == "Display P3")
    }

    @Test func visuallyLossless_spec7_4_keepsPriorNotesAndMetadata() throws {
        var image = try Decode.decode(ImageFixtures.jpegWithGainMap())
        image.notes = [.keptFullColor]
        let out = try JPEGEncode.visuallyLossless(image, plan(lossless: true, keep: true))
        #expect(out.notes == [.keptFullColor, .hdrRemoved, .reencodedVisuallyLossless])
    }
}
