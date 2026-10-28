import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UnderpressuredCore
@testable import ImageEngine

private struct Result {
    let encoded: EncodedImage
    let source: CGImageSource
    let image: CGImage
    let properties: [String: Any]

    var type: UTType? { CGImageSourceGetType(source).flatMap { UTType($0 as String) } }
    func group(_ key: CFString) -> [String: Any]? { properties[key as String] as? [String: Any] }
}

private func encode(
    _ data: Data, format: WritableFormat, quality: Int = 80, lossless: Bool = false, keep: Bool = false
) throws -> Result {
    let image = try Decode.decode(data)
    let encoded = try Encode.encode(
        image, EncodePlan(format: format, quality: Quality.clamping(quality), lossless: lossless, keepMetadata: keep))
    let source = try #require(CGImageSourceCreateWithData(encoded.data as CFData, nil))
    return Result(
        encoded: encoded, source: source, image: try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)),
        properties: try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]))
}

@Suite struct EncodeTests {
    @Test func encode_spec7_4_jpegIsProgressiveJPEG() throws {
        let out = try encode(try ImageFixtures.rgbJPEG(width: 96, height: 64), format: .jpeg)
        #expect(out.type == .jpeg)
        #expect(out.encoded.format == .jpeg)
        #expect(out.group(kCGImagePropertyJFIFDictionary)?[kCGImagePropertyJFIFIsProgressive as String] as? Bool == true)
        #expect(out.image.width == 96 && out.image.height == 64)
        #expect(out.encoded.pixelWidth == 96 && out.encoded.pixelHeight == 64)
    }

    @Test func encode_spec7_4_jpegQualityScalesSize() throws {
        let data = try ImageFixtures.rgbPNG(width: 96, height: 64)
        let low = try encode(data, format: .jpeg, quality: 20).encoded.data.count
        let high = try encode(data, format: .jpeg, quality: 95).encoded.data.count
        #expect(low < high)
    }

    @Test func encode_spec7_4_pngIsPNG() throws {
        let out = try encode(try ImageFixtures.rgbJPEG(), format: .png)
        #expect(out.type == .png)
        #expect(out.encoded.format == .png)
        #expect(out.image.width == 96 && out.image.height == 64)
    }

    @Test func encode_spec7_4_orientedPixelsKeepSize() throws {
        let out = try encode(try ImageFixtures.jpeg(orientation: 6), format: .jpeg, keep: true)
        #expect(out.image.width == 20 && out.image.height == 40)
        #expect(out.encoded.pixelWidth == 20 && out.encoded.pixelHeight == 40)
        #expect(out.properties[kCGImagePropertyOrientation as String] as? Int ?? 1 == 1)
    }

    @Test func encode_spec7_4_cmykBecomesSRGB() throws {
        for format in WritableFormat.allCases {
            let out = try encode(try ImageFixtures.cmykJPEG(), format: format)
            #expect(out.image.colorSpace?.model == .rgb)
            #expect(out.properties[kCGImagePropertyColorModel as String] as? String == "RGB")
            #expect(out.image.width == 64 && out.image.height == 48)
        }
    }

    @Test func encode_spec7_4_sixteenBitBecomesEightForJPEG() throws {
        let out = try encode(try ImageFixtures.png16(), format: .jpeg)
        #expect(out.image.bitsPerComponent == 8)
    }

    @Test func encode_spec7_4_sixteenBitBecomesEightForLossyPNG() throws {
        let out = try encode(try ImageFixtures.png16(), format: .png, lossless: false)
        #expect(out.image.bitsPerComponent == 8)
        #expect(out.properties[kCGImagePropertyDepth as String] as? Int == 8)
    }

    @Test func encode_spec7_4_sixteenBitStaysForLosslessPNG() throws {
        let out = try encode(try ImageFixtures.png16(), format: .png, lossless: true)
        #expect(out.image.bitsPerComponent == 16)
        #expect(out.properties[kCGImagePropertyDepth as String] as? Int == 16)
        #expect(out.type == .png)
    }

    @Test func encode_spec7_4_eightBitStaysEightForLosslessPNG() throws {
        let out = try encode(try ImageFixtures.rgbPNG(), format: .png, lossless: true)
        #expect(out.image.bitsPerComponent == 8)
    }

    @Test(arguments: WritableFormat.allCases, [true, false])
    func encode_spec7_4_grayscaleStaysGray(format: WritableFormat, png: Bool) throws {
        let data = png ? try ImageFixtures.grayscalePNG() : try ImageFixtures.grayscaleJPEG()
        let out = try encode(data, format: format)
        #expect(out.image.colorSpace?.model == .monochrome)
        #expect(out.properties[kCGImagePropertyColorModel as String] as? String == "Gray")
    }

    @Test func encode_spec7_4_jpegNeverHasAlpha() throws {
        let out = try encode(try ImageFixtures.rgbaPNG(), format: .jpeg)
        #expect(out.type == .jpeg)
        #expect(!Redraw.hasAlpha(out.image))
        #expect(out.properties[kCGImagePropertyHasAlpha as String] as? Bool != true)
        // Transparent half was composited onto white.
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(out.image, in: CGRect(x: -(out.image.width - 2), y: -2, width: out.image.width, height: out.image.height))
        #expect(rgba[0] > 240 && rgba[1] > 240 && rgba[2] > 240)
    }

    @Test func encode_spec7_4_pngKeepsAlpha() throws {
        let out = try encode(try ImageFixtures.rgbaPNG(), format: .png)
        #expect(Redraw.hasAlpha(out.image))
    }

    @Test func encode_spec7_4_iccProfileSurvives() throws {
        let source = try Decode.decode(try ImageFixtures.displayP3JPEG())
        for format in WritableFormat.allCases {
            let out = try encode(try ImageFixtures.displayP3JPEG(), format: format)
            #expect(out.image.colorSpace?.copyICCData() as Data? == source.facts.iccProfile)
        }
    }

    @Test func encode_spec7_3_notesCombineImageAndMetadataNotes() throws {
        var image = try Decode.decode(try ImageFixtures.jpegWithGainMap())
        image.notes = [.resized(from: 96, to: 48)]
        let encoded = try Encode.encode(
            image, EncodePlan(format: .jpeg, quality: 80, lossless: false, keepMetadata: true))
        #expect(encoded.notes == [.resized(from: 96, to: 48), .hdrRemoved])
    }

    @Test func encode_spec7_3_keepMetadataFlag() throws {
        let data = try ImageFixtures.jpegWithAllMetadata()
        let kept = try encode(data, format: .jpeg, keep: true)
        let stripped = try encode(data, format: .jpeg, keep: false)
        #expect(kept.group(kCGImagePropertyGPSDictionary) != nil)
        #expect(stripped.group(kCGImagePropertyGPSDictionary) == nil)
    }
}
