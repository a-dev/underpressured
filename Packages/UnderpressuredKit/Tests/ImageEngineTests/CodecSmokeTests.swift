import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageEngine

private let side = 64

private func gradient(components: Int) -> [UInt8] {
    var px = [UInt8](repeating: 255, count: side * side * components)
    for y in 0..<side {
        for x in 0..<side {
            let i = (y * side + x) * components
            px[i] = UInt8(x * 4)
            if components >= 3 {
                px[i + 1] = UInt8(y * 4)
                px[i + 2] = UInt8((x + y) * 2)
            }
        }
    }
    return px
}

private func imageSource(_ data: Data) throws -> CGImageSource {
    try #require(CGImageSourceCreateWithData(data as CFData, nil))
}

private func expectImage(_ data: Data, type: UTType) throws -> CGImageSource {
    let src = try imageSource(data)
    #expect(CGImageSourceGetType(src).flatMap { UTType($0 as String) } == type)
    let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    #expect(image.width == side)
    #expect(image.height == side)
    return src
}

private func makePNG(rgba: [UInt8]) throws -> Data {
    let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
    let image = try #require(CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let out = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    return out as Data
}

@Suite struct CodecSmokeTests {
    @Test func jpegliRGB() throws {
        let px = gradient(components: 3)
        let jpeg = try px.withUnsafeBytes {
            try Jpegli.encode(pixels: $0, width: side, height: side, bytesPerRow: side * 3,
                              components: .rgb, quality: 80, progressive: true, iccProfile: nil)
        }
        _ = try expectImage(jpeg, type: .jpeg)
    }

    @Test func jpegliGray() throws {
        let px = gradient(components: 1)
        let jpeg = try px.withUnsafeBytes {
            try Jpegli.encode(pixels: $0, width: side, height: side, bytesPerRow: side,
                              components: .gray, quality: 80, progressive: false, iccProfile: nil)
        }
        _ = try expectImage(jpeg, type: .jpeg)
    }

    @Test func jpegliRejectsShortBuffer() {
        let px = [UInt8](repeating: 0, count: 10)
        #expect(throws: JpegliError.invalidArgument) {
            try px.withUnsafeBytes {
                try Jpegli.encode(pixels: $0, width: side, height: side, bytesPerRow: side * 3,
                                  components: .rgb, quality: 80, progressive: false, iccProfile: nil)
            }
        }
    }

    @Test func oxipngOptimizes() throws {
        let png = try makePNG(rgba: gradient(components: 4))
        let optimized = try Oxipng.optimize(png, level: 2)
        _ = try expectImage(optimized, type: .png)
    }

    @Test func oxipngRejectsGarbage() {
        #expect(throws: OxipngError.self) {
            try Oxipng.optimize(Data([1, 2, 3, 4]), level: 2)
        }
    }

    @Test func quantizrProducesIndexedPNG() throws {
        let px = gradient(components: 4)
        let png = try px.withUnsafeBytes {
            try Quantizr.quantize(rgba: $0, width: side, height: side, bytesPerRow: side * 4,
                                  maxColors: 16, dither: 0.5, oxipngLevel: 2)
        }
        let src = try expectImage(png, type: .png)
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyIsIndexed] as? Bool == true)
    }

    @Test func quantizrRejectsBadMaxColors() {
        let px = gradient(components: 4)
        #expect(throws: QuantizrError.invalidArgument) {
            try px.withUnsafeBytes {
                try Quantizr.quantize(rgba: $0, width: side, height: side, bytesPerRow: side * 4,
                                      maxColors: 1, dither: 0.5, oxipngLevel: 2)
            }
        }
    }
}
