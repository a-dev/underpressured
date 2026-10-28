import UnderpressuredApplication
import CoreGraphics
import Foundation
import Testing
import UnderpressuredCore
@testable import ImageEngine

private func colorSpace(_ name: CFString) throws -> CGColorSpace {
    try #require(CGColorSpace(name: name))
}

private func facts(hasAlpha: Bool, bits: Int = 8, gray: Bool = false) -> SourceFacts {
    SourceFacts(format: .png, bitsPerComponent: bits, isGrayscale: gray, isCMYK: false,
                hasAlpha: hasAlpha, hasGainMap: false, iccProfile: nil)
}

/// 4x1 premultiplied RGBA8 sRGB: transparent, opaque red, opaque blue, 50% black.
private func rgbaImage() throws -> CGImage {
    let bytes: [UInt8] = [
        0, 0, 0, 0,
        255, 0, 0, 255,
        0, 0, 255, 255,
        0, 0, 0, 128,
    ]
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    return try #require(CGImage(
        width: 4, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
        space: try colorSpace(CGColorSpace.sRGB),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

/// Reads the image back as 8-bit RGB (alpha skipped) in sRGB, one entry per pixel.
private func readRGB(_ image: CGImage) throws -> [(r: Int, g: Int, b: Int)] {
    let w = image.width
    let h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = try #require(CGContext(
        data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: try colorSpace(CGColorSpace.sRGB),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (0..<w * h).map { i in (Int(bytes[i * 4]), Int(bytes[i * 4 + 1]), Int(bytes[i * 4 + 2])) }
}

private func expectNear(_ actual: (r: Int, g: Int, b: Int), _ expected: Int, tolerance: Int = 2) {
    #expect(abs(actual.r - expected) <= tolerance)
    #expect(abs(actual.g - expected) <= tolerance)
    #expect(abs(actual.b - expected) <= tolerance)
}

@Suite struct FlattenTests {
    @Test func flatten_spec7_3_transparentBecomesWhite_opaqueKept_halfBlendsOntoWhite() throws {
        let input = DecodedImage(
            pixels: try rgbaImage(), facts: facts(hasAlpha: true),
            metadata: SourceMetadata())
        let out = try Flatten.ontoWhite(input)

        #expect(out.pixels.width == 4)
        #expect(out.pixels.height == 1)
        #expect(out.pixels.alphaInfo == .none || out.pixels.alphaInfo == .noneSkipLast)
        #expect(out.facts.hasAlpha == false)
        #expect(out.pixels.colorSpace?.name == input.pixels.colorSpace?.name)

        let px = try readRGB(out.pixels)
        expectNear(px[0], 255)                       // transparent -> white
        #expect(px[1].r == 255 && px[1].g == 0 && px[1].b == 0)  // opaque red unchanged
        #expect(px[2].r == 0 && px[2].g == 0 && px[2].b == 255)  // opaque blue unchanged
        expectNear(px[3], 128)                       // 50% black over white
    }

    @Test func flatten_spec7_3_opaqueImageReturnedUnchanged() throws {
        // A 2x2 image with no alpha channel.
        let ctx = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: try colorSpace(CGColorSpace.sRGB),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let noAlpha = try #require(ctx.makeImage())

        let input = DecodedImage(pixels: noAlpha, facts: facts(hasAlpha: false), metadata: SourceMetadata())
        let out = try Flatten.ontoWhite(input)
        #expect(out.pixels === input.pixels)
        #expect(out.facts == input.facts)
    }

    @Test func flatten_spec7_3_grayAlphaUsesGrayContext() throws {
        // 2x1 gray + alpha, premultiplied: transparent, then 50% black.
        let bytes: [UInt8] = [0, 0, 0, 128]
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let grayspace = try colorSpace(CGColorSpace.genericGrayGamma2_2)
        let gray = try #require(CGImage(
            width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 16, bytesPerRow: 4,
            space: grayspace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))

        let out = try Flatten.ontoWhite(DecodedImage(
            pixels: gray, facts: facts(hasAlpha: true, gray: true), metadata: SourceMetadata()))
        #expect(out.pixels.colorSpace?.model == .monochrome)
        #expect(out.pixels.alphaInfo == .none)
        #expect(out.facts.hasAlpha == false)
        #expect(out.facts.isGrayscale)
    }

    @Test func flatten_spec7_3_sixteenBitKeepsDepth() throws {
        // 2x1 RGBA16, little-endian: transparent, then 50% black.
        var bytes = [UInt8]()
        for value: UInt16 in [0, 0, 0, 0, 0, 0, 0, 0x8000] {
            bytes += [UInt8(value & 0xff), UInt8(value >> 8)]
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let space = try colorSpace(CGColorSpace.sRGB)
        let image = try #require(CGImage(
            width: 2, height: 1, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 16,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))

        let out = try Flatten.ontoWhite(DecodedImage(
            pixels: image, facts: facts(hasAlpha: true, bits: 16), metadata: SourceMetadata()))
        #expect(out.pixels.bitsPerComponent == 16)
        #expect(out.pixels.alphaInfo == .noneSkipLast)
        #expect(out.facts.bitsPerComponent == 16)
        #expect(out.facts.hasAlpha == false)
    }
}
