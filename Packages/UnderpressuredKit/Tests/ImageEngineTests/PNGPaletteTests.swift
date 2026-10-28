import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UnderpressuredCore
@testable import ImageEngine

/// A PNG drawn by `fill(x, y) -> (r, g, b, a)`.
private func png(width: Int = 128, height: Int = 96, _ fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> Data {
    var px = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b, a) = fill(x, y)
            let i = (y * width + x) * 4
            px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = a
        }
    }
    let provider = try #require(CGDataProvider(data: Data(px) as CFData))
    let image = try #require(CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    return out as Data
}

/// Flat UI-like blocks: few colors, the case a palette wins.
private func screenshot() throws -> Data {
    try png { x, y in
        let palette: [(UInt8, UInt8, UInt8)] = [(240, 240, 240), (30, 120, 220), (20, 20, 20), (250, 200, 40)]
        let c = palette[(x / 32 + y / 24) % palette.count]
        return (c.0 - UInt8((x + y) % 8), c.1, c.2, 255)
    }
}

/// Smooth noisy gradient: a palette can't reach a high floor.
private func photo() throws -> Data {
    var seed: UInt32 = 1
    return try png(width: 256, height: 256) { x, y in
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let n = Int(seed >> 28) - 8
        func c(_ v: Int) -> UInt8 { UInt8(clamping: v + n) }
        return (c(x), c(y), c((x + y) / 2), 255)
    }
}

private func indexed(_ data: Data) throws -> Bool {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return CGImageSourceCreateImageAtIndex(source, 0, nil)?.colorSpace?.model == .indexed
}

/// Independent encoded-value compositing: round once after floating-point source-over.
private func composite(_ rgba: [UInt8], background: UInt8) -> [UInt8] {
    stride(from: 0, to: rgba.count, by: 4).flatMap { offset in
        let alpha = Double(rgba[offset + 3]) / 255
        return (0..<3).map { channel in
            UInt8((Double(rgba[offset + channel]) * alpha + Double(background) * (1 - alpha)).rounded())
        }
    }
}

private func metric(_ reference: [UInt8], _ candidate: [UInt8], background: UInt8) throws -> Double {
    let a = composite(reference, background: background)
    let b = composite(candidate, background: background)
    return try a.withUnsafeBytes { ra in
        try b.withUnsafeBytes { rb in
            try Jpegli.ssimulacra2(reference: ra, distorted: rb, width: 128, height: 96,
                                  bytesPerRow: 128 * 3, components: .rgb)
        }
    }
}

@Suite struct PNGPaletteTests {
    private func run(_ data: Data, quality: Int) throws -> EncodedImage {
        try PNGPalette.encode(try Decode.decode(data), EncodePlan(format: .png, quality: Quality.clamping(quality), lossless: false, keepMetadata: false))
    }

    @Test func ssimFloor_q6_piecewiseLinear() {
        #expect(PNGPalette.ssimFloor(0) == 30)
        #expect(PNGPalette.ssimFloor(57) == 70)
        #expect(PNGPalette.ssimFloor(85) == 80)
        #expect(PNGPalette.ssimFloor(98) == 90)
        #expect(PNGPalette.ssimFloor(100) == 90)
        #expect(abs(PNGPalette.ssimFloor(71) - 75) < 1e-9)
    }

    @Test func encode_spec7_4_flatImageGetsPaletteThatMeetsFloor() throws {
        let source = try screenshot()
        let out = try run(source, quality: 80)
        #expect(out.format == .png && out.pixelWidth == 128 && out.pixelHeight == 96)
        #expect(!out.notes.contains(.keptFullColor))
        #expect(try indexed(out.data))
        let reference = try PixelBuffer.render(try Decode.decode(source).pixels, layout: .rgba8, sourceProfile: nil)
        #expect(try PNGPalette.score(out.data, against: reference) >= PNGPalette.ssimFloor(80))
    }

    @Test func encode_spec7_4_photoAtHighQualityKeepsFullColor() throws {
        let out = try run(try photo(), quality: 95)
        #expect(out.notes.contains(.keptFullColor))
        #expect(try !indexed(out.data))
    }

    @Test func encode_spec7_4_paletteKeepsICCProfile() throws {
        let out = try run(try screenshot(), quality: 80)
        let source = try #require(CGImageSourceCreateWithData(out.data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyProfileName] as? String != nil)
    }

    @Test(arguments: [UInt8(0), UInt8(255)])
    func transparencyUsesWorstBackgroundAndRejectsCandidate(color: UInt8) throws {
        func pixels(alpha: UInt8) -> [UInt8] {
            (0..<(128 * 96)).flatMap { index -> [UInt8] in
                let x = index % 128
                return [color, color, color, x < 32 ? 0 : (x >= 96 ? 255 : alpha)]
            }
        }
        let reference = pixels(alpha: 128)
        let candidate = pixels(alpha: 180)
        let candidatePNG = try png { x, _ in
            (color, color, color, x < 32 ? 0 : (x >= 96 ? 255 : 180))
        }
        let source = PixelBuffer(bytes: reference, width: 128, height: 96, bytesPerRow: 128 * 4,
                                 layout: .rgba8, iccProfile: nil)
        let dark = try metric(reference, candidate, background: 26)
        let light = try metric(reference, candidate, background: 230)
        // Black alpha errors disappear on dark backgrounds; white errors disappear on light ones.
        #expect(color == 0 ? light < dark : dark < light)
        #expect(abs(dark - light) > 5)
        let floor = 30.0 // The production quality-0 acceptance floor, independent of ssimFloor.
        #expect(min(dark, light) < floor && max(dark, light) > floor)
        // Both compositors round to nearest 8-bit value; allow only metric floating-point noise.
        let actual = try PNGPalette.score(candidatePNG, against: source)
        #expect(abs(actual - min(dark, light)) < 0.001)
        var search = PNGPalette.Search(source: source, floor: floor, candidate: { _, _ in candidatePNG })
        #expect(try search.run() == nil)
        #expect(!search.results.isEmpty)
        #expect(search.results.values.allSatisfy { !$0.passes })
        let exactPNG = try png { x, _ in
            (color, color, color, x < 32 ? 0 : (x >= 96 ? 255 : 128))
        }
        var passing = PNGPalette.Search(source: source, floor: floor, candidate: { _, _ in exactPNG })
        #expect(try passing.run() == exactPNG)
    }

    @Test func encodedPaletteRetainsTransparentAndPartialPixels() throws {
        let source = try png { x, y in
            (200 - UInt8((x + y) % 8), 50, 50, x < 32 ? 0 : (x < 80 ? 128 : 255))
        }
        let out = try run(source, quality: 80)
        #expect(!out.notes.contains(.keptFullColor))
        #expect(out.data[25] == 3)
        let image = try Decode.decode(out.data)
        let pixels = try PixelBuffer.render(image.pixels, layout: .rgba8, sourceProfile: nil)
        #expect(pixels.width == 128 && pixels.height == 96)
        for (x, expectedAlpha) in [(16, 0), (56, 128), (104, 255)] {
            let offset = (48 * 128 + x) * 4
            #expect(abs(Int(pixels.bytes[offset + 3]) - expectedAlpha) <= 1)
            if expectedAlpha > 0 {
                #expect(abs(Int(pixels.bytes[offset]) - 196) <= 8)
                #expect(abs(Int(pixels.bytes[offset + 1]) - 50) <= 2)
                #expect(abs(Int(pixels.bytes[offset + 2]) - 50) <= 2)
            }
        }
    }

    @Test func finalizedSizeIncludesColorAndMetadataBeforeSelection() throws {
        // A tiny exact-color image has a smaller lossless encoding once both containers are complete.
        var image = try Decode.decode(png { x, _ in (200, 50, 50, x < 64 ? 0 : 255) })
        image.metadata.properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: "size-check"]
        let plan = EncodePlan(format: .png, quality: 80, lossless: false, keepMetadata: true)
        var losslessPlan = plan
        losslessPlan.lossless = true
        let lossless = try PNGLossless.encode(image, losslessPlan)
        let pixels = try PixelBuffer.render(image.pixels, layout: .rgba8, sourceProfile: image.facts.iccProfile)
        var search = PNGPalette.Search(source: pixels, floor: PNGPalette.ssimFloor(80))
        let candidate = try search.run()
        let raw = try #require(candidate)
        let final = try PNGChunks.finalizePalette(raw, using: lossless.data)
        #expect(raw.count < lossless.data.count)
        #expect(final.count >= lossless.data.count)
        let output = try PNGPalette.encode(image, plan)
        #expect(output.data == lossless.data)
        #expect(output.notes.contains(.keptFullColor))
        // Finalization retains the serialized indexed pixel layout and transparent pixels.
        #expect(final[25] == 3)
        #expect(try PixelBuffer.render(Decode.decode(final).pixels, layout: .rgba8, sourceProfile: nil).hasTransparency)
        let props = try Decode.decode(final).metadata.properties
        #expect((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String == "size-check")
    }


    @Test func grayPaletteUsesSRGBInsteadOfGrayICC() throws {
        let width = 512
        let height = 384
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * width + x] = UInt8(40 + ((x / 16 + y / 16) % 3) * 60 + (x / 16 * 17 + y / 16 * 13) % 32)
            }
        }
        let pixels = try #require(context.makeImage())
        let profile = try #require(space.copyICCData() as Data?)
        let image = DecodedImage(pixels: pixels, facts: SourceFacts(
            format: .png, bitsPerComponent: 8, isGrayscale: true, isCMYK: false,
            hasAlpha: false, hasGainMap: false, iccProfile: profile), metadata: SourceMetadata())
        let output = try PNGPalette.encode(image, EncodePlan(format: .png, quality: 80, lossless: false, keepMetadata: false))
        #expect(!output.notes.contains(.keptFullColor))
        #expect(output.data[25] == 3)
        let decoded = try Decode.decode(output.data)
        let colorSpace = try #require(decoded.pixels.colorSpace)
        let rgb = colorSpace.model == .indexed ? colorSpace.baseColorSpace : colorSpace
        #expect(rgb?.copyICCData() as Data? == CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData() as Data?)
    }

}
