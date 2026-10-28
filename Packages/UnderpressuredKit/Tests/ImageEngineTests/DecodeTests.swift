import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UnderpressuredCore
@testable import ImageEngine

/// RGBA8 pixel at (x, y), top-left origin, converted to sRGB.
private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return out
}

private func isRed(_ p: [UInt8]) -> Bool { p[0] > 200 && p[1] < 60 && p[2] < 60 }
private func isGreen(_ p: [UInt8]) -> Bool { p[1] > 200 && p[0] < 60 && p[2] < 60 }

private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

/// Where the red (stored top-left) and green (stored top-right) markers end up once the image is upright.
private let expectedMarkers: [Int: (red: Corner, green: Corner)] = [
    1: (.topLeft, .topRight), 2: (.topRight, .topLeft), 3: (.bottomRight, .bottomLeft),
    4: (.bottomLeft, .bottomRight), 5: (.topLeft, .bottomLeft), 6: (.topRight, .bottomRight),
    7: (.bottomRight, .topRight), 8: (.bottomLeft, .topLeft)
]

private func center(_ corner: Corner, in image: CGImage) -> (x: Int, y: Int) {
    let m = ImageFixtures.markerSize / 2
    switch corner {
    case .topLeft: return (m, m)
    case .topRight: return (image.width - 1 - m, m)
    case .bottomLeft: return (m, image.height - 1 - m)
    case .bottomRight: return (image.width - 1 - m, image.height - 1 - m)
    }
}

@Suite struct DecodeTests {
    @Test(arguments: 1...8)
    func decode_spec7_3_appliesOrientation(orientation: Int) throws {
        let image = try Decode.decode(try ImageFixtures.jpeg(orientation: orientation, width: 40, height: 20))
        let swaps = orientation >= 5
        #expect(image.pixels.width == (swaps ? 20 : 40))
        #expect(image.pixels.height == (swaps ? 40 : 20))
        let expected = try #require(expectedMarkers[orientation])
        let red = center(expected.red, in: image.pixels)
        let green = center(expected.green, in: image.pixels)
        #expect(isRed(pixel(image.pixels, x: red.x, y: red.y)))
        #expect(isGreen(pixel(image.pixels, x: green.x, y: green.y)))
    }

    @Test(arguments: 1...8)
    func inspect_spec7_3_reportsDisplayedSize(orientation: Int) throws {
        let info = try Decode.inspect(try ImageFixtures.jpeg(orientation: orientation, width: 40, height: 20))
        #expect(info.format == .jpeg)
        #expect(info.frameCount == 1)
        #expect(info.pixelWidth == (orientation >= 5 ? 20 : 40))
        #expect(info.pixelHeight == (orientation >= 5 ? 40 : 20))
    }

    @Test func inspect_spec7_2_formats() throws {
        #expect(try Decode.inspect(try ImageFixtures.rgbPNG()).format == .png)
        #expect(try Decode.inspect(try ImageFixtures.multiPageTIFF(pages: 3)).format == .tiff)
        #expect(try Decode.inspect(try ImageFixtures.multiPageTIFF(pages: 3)).frameCount == 3)
    }

    @Test func inspect_spec7_2_animatedFrameCount() throws {
        let data = try ImageFixtures.animatedGIF(frames: 4)
        // GIF is not an accepted format; Intake decides before Decode. Either an unreadable error or the count.
        if let info = try? Decode.inspect(data) { #expect(info.frameCount == 4) }
    }

    @Test func decode_spec7_4_cmykStaysCMYK() throws {
        let image = try Decode.decode(try ImageFixtures.cmykJPEG(width: 64, height: 48))
        #expect(image.facts.isCMYK)
        #expect(!image.facts.isGrayscale)
        #expect(image.pixels.colorSpace?.model == .cmyk)
        #expect(image.pixels.width == 64 && image.pixels.height == 48)
    }

    @Test func decode_spec7_4_sixteenBitStaysSixteen() throws {
        let image = try Decode.decode(try ImageFixtures.png16())
        #expect(image.facts.bitsPerComponent == 16)
        #expect(image.pixels.bitsPerComponent == 16)
        #expect(image.facts.format == .png)
    }

    @Test(arguments: [true, false])
    func decode_spec7_4_grayscaleStaysGray(png: Bool) throws {
        let data = png ? try ImageFixtures.grayscalePNG() : try ImageFixtures.grayscaleJPEG()
        let image = try Decode.decode(data)
        #expect(image.facts.isGrayscale)
        #expect(image.pixels.colorSpace?.model == .monochrome)
        #expect(!image.facts.isCMYK)
    }

    @Test func decode_spec7_4_grayscaleOrientedStaysGray() throws {
        // Orientation redraw must keep gray: build a rotated gray JPEG on the fly.
        let base = try ImageFixtures.grayscaleJPEG(width: 64, height: 48)
        let source = try #require(CGImageSourceCreateWithData(base as CFData, nil))
        let cg = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let image = try Decode.decode(out as Data)
        #expect(image.pixels.width == 48 && image.pixels.height == 64)
        #expect(image.pixels.colorSpace?.model == .monochrome)
    }

    @Test func decode_spec7_4_alphaFact() throws {
        #expect(try Decode.decode(try ImageFixtures.rgbaPNG()).facts.hasAlpha)
        #expect(!(try Decode.decode(try ImageFixtures.rgbJPEG()).facts.hasAlpha))
    }

    @Test func decode_spec7_3_gainMapFact() throws {
        #expect(try Decode.decode(try ImageFixtures.jpegWithGainMap()).facts.hasGainMap)
        #expect(!(try Decode.decode(try ImageFixtures.rgbJPEG()).facts.hasGainMap))
    }

    @Test func decode_spec7_3_iccProfile() throws {
        let image = try Decode.decode(try ImageFixtures.displayP3JPEG())
        let icc = try #require(image.facts.iccProfile)
        let space = try #require(CGColorSpace(iccData: icc as CFData))
        #expect(space.copyICCData() as Data? == icc)
        #expect(image.pixels.colorSpace?.copyICCData() as Data? == icc)
        #expect(image.metadata.properties[kCGImagePropertyProfileName] as? String == "Display P3")
    }

    @Test func decode_spec7_3_carriesMetadata() throws {
        let image = try Decode.decode(try ImageFixtures.jpegWithAllMetadata())
        #expect(image.metadata.properties[kCGImagePropertyExifDictionary] != nil)
        #expect(image.metadata.properties[kCGImagePropertyGPSDictionary] != nil)
        #expect(image.metadata.properties[kCGImagePropertyIPTCDictionary] != nil)
        #expect(image.metadata.xmp != nil)
    }

    @Test func decode_spec7_3_garbageIsUnreadable() {
        let garbage = Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        #expect(throws: CodecError.unreadable) { try Decode.decode(garbage) }
        #expect(throws: CodecError.unreadable) { try Decode.inspect(garbage) }
        #expect(throws: CodecError.unreadable) { try Decode.decode(Data()) }
    }

    @Test func decode_spec7_3_truncatedIsUnreadable() throws {
        let data = try ImageFixtures.rgbPNG()
        let truncated = data.prefix(20)
        #expect(throws: CodecError.unreadable) { try Decode.decode(Data(truncated)) }
    }
}
