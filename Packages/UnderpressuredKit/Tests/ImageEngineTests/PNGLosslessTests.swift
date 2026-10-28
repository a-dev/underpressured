import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UnderpressuredCore
@testable import ImageEngine

private func plan(keep: Bool = false) -> EncodePlan {
    EncodePlan(format: .png, quality: 100, lossless: true, keepMetadata: keep)
}

private func cgImage(_ data: Data) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

/// Pixels as 8- or 16-bit premultiplied-last RGBA (or gray) in the image's own color space.
private func bitmap(_ image: CGImage, bits: Int, gray: Bool) throws -> [UInt8] {
    let space = gray ? CGColorSpaceCreateDeviceGray() : try #require(image.colorSpace)
    let channels = gray ? 1 : 4
    let bytes = image.width * image.height * channels * bits / 8
    var buffer = [UInt8](repeating: 0, count: bytes)
    let info: CGBitmapInfo = gray
        ? CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        : CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            | (bits == 16 ? CGBitmapInfo.byteOrder16Big.rawValue : 0))
    try buffer.withUnsafeMutableBytes { raw in
        let context = try #require(CGContext(
            data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: bits,
            bytesPerRow: image.width * channels * bits / 8, space: space, bitmapInfo: info.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return buffer
}

private func expectSamePixels(_ source: Data, _ output: Data, bits: Int, gray: Bool = false) throws {
    let a = try cgImage(source), b = try cgImage(output)
    #expect(a.width == b.width && a.height == b.height)
    #expect(try bitmap(a, bits: bits, gray: gray) == bitmap(b, bits: bits, gray: gray))
}

private func props(_ data: Data) throws -> [String: Any] {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
}

@Suite struct PNGLosslessTests {
    @Test(arguments: [true, false], [true, false])
    func nativeLosslessPreservesTransformedPixels(jpegSource: Bool, resize: Bool) async throws {
        let codec = NativeCodec()
        let data = jpegSource ? try ImageFixtures.rgbJPEG() : try ImageFixtures.rgbaPNG()
        let decoded = try await codec.decode(data)
        let transformed = try await codec.transform(decoded, TransformPlan(
            resizeRule: resize ? .maxLongEdge(32) : .none, flattenOntoWhite: false))
        let output = try await codec.encode(transformed, plan())
        let pixels = try cgImage(output.data)
        #expect(pixels.width == transformed.pixels.width && pixels.height == transformed.pixels.height)
        if resize { #expect(max(pixels.width, pixels.height) == 32) }
        #expect(try bitmap(pixels, bits: 8, gray: false)
            == bitmap(transformed.pixels, bits: 8, gray: false))
    }

    private func run(_ data: Data, keep: Bool = false) throws -> EncodedImage {
        try PNGLossless.encode(try Decode.decode(data), plan(keep: keep))
    }

    @Test func encode_spec7_4_rgbPixelsIdentical() throws {
        let source = try ImageFixtures.rgbPNG()
        let out = try run(source)
        #expect(out.format == .png && out.pixelWidth == 96 && out.pixelHeight == 64)
        try expectSamePixels(source, out.data, bits: 8)
    }

    @Test func encode_spec7_4_rgbaPixelsIdentical() throws {
        let source = try ImageFixtures.rgbaPNG()
        try expectSamePixels(source, try run(source).data, bits: 8)
    }

    @Test func encode_spec7_4_sixteenBitStaysSixteen() throws {
        let source = try ImageFixtures.png16()
        let out = try run(source)
        #expect(try cgImage(out.data).bitsPerComponent == 16)
        try expectSamePixels(source, out.data, bits: 16)
    }

    @Test func encode_spec7_4_grayscaleStaysGray() throws {
        let source = try ImageFixtures.grayscalePNG()
        let out = try run(source)
        #expect(try cgImage(out.data).colorSpace?.model == .monochrome)
        try expectSamePixels(source, out.data, bits: 8, gray: true)
    }

    @Test func encode_spec7_3_displayP3ProfileKept() throws {
        let source = try ImageFixtures.displayP3PNG()
        for keep in [false, true] {
            let out = try run(source, keep: keep)
            #expect(try props(out.data)[kCGImagePropertyProfileName as String] as? String == "Display P3")
            try expectSamePixels(source, out.data, bits: 8)
        }
    }

    @Test func encode_spec7_4_notLargerThanImageIO() throws {
        let image = try Decode.decode(try ImageFixtures.rgbPNG())
        let plain = try Encode.encode(image, plan())
        #expect(try PNGLossless.encode(image, plan()).data.count <= plain.data.count)
    }

    @Test func encode_spec7_4_optimizeRejectsGarbage() {
        #expect(throws: CodecError.self) { try PNGLossless.optimize(Data([1, 2, 3])) }
    }

    @Test func encode_spec7_3_keptMetadataSurvivesOxipng() throws {
        let image = try Decode.decode(try ImageFixtures.jpegWithAllMetadata())
        let kept = try PNGLossless.encode(image, plan(keep: true)).data
        let plainKept = try Encode.encode(image, plan(keep: true)).data
        let stripped = try PNGLossless.encode(image, plan(keep: false)).data
        let before = try props(plainKept), after = try props(kept)
        #expect(before[kCGImagePropertyTIFFDictionary as String] != nil)  // fixture sanity
        #expect(after[kCGImagePropertyTIFFDictionary as String] != nil)
        #expect(after[kCGImagePropertyExifDictionary as String] != nil)
        #expect(try props(stripped)[kCGImagePropertyTIFFDictionary as String] == nil)
        // ImageIO reports a synthesized Exif group (pixel size) for any PNG; the user's fields must be gone.
        let strippedExif = try props(stripped)[kCGImagePropertyExifDictionary as String] as? [String: Any]
        #expect(strippedExif?[kCGImagePropertyExifUserComment as String] == nil)
        #expect(try props(stripped)[kCGImagePropertyGPSDictionary as String] == nil)
    }
}
