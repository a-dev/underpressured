import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Creates a repeatable, detailed image for JPEG fidelity comparisons.
///
/// Calibration (Apple Silicon, macOS 27.0.1, Xcode 27.1, pinned jpegli
/// 031a0077f5799a6041004267fc12b956c1f52a20):
/// - JPEG decoded then resized to 128×96: distance 1 = 63.4817; distance 10 = 39.7828.
/// - PNG converted at 256×192: distance 1 = 81.9762; distance 10 = 51.7946.
/// Floors 55 and 70 leave 8.48 and 11.98 points below the real outputs, and
/// 15.22 and 18.21 points above the degraded controls. Control ceilings 45 and 60
/// also require the fixture to retain its separating power. These empirical
/// SSIMULACRA2 bounds protect this fixture, not a universal Butteraugli definition.
/// The initial common trial floor of 70 rejected the resized reference; per-path
/// bounds reflect the measured 23.70/30.18-point gaps rather than hiding degradation.
/// Recalibrate explicitly on a toolchain change; do not automatically lower floors.
/// Only the toolchain above has been exercised; other toolchains are unverified.
enum JPEGFidelityFixture {
    private static let width = 256
    private static let height = 192

    static func data(jpeg: Bool) throws -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let gradientR = x * 255 / (width - 1)
                let gradientG = y * 255 / (height - 1)
                let gradientB = (x + y) * 255 / (width + height - 2)
                // Fixed integer hash adds fine texture without runtime randomness.
                var hash = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ 0x5EED)
                hash = (hash ^ (hash >> 13)) &* 1_274_126_177
                let texture = Int((hash ^ (hash >> 16)) & 31) - 15

                let edge = x % 64 < 2 || y % 48 < 2
                let block = (x / 32 + y / 24) % 2 == 0
                pixels[index] = UInt8(clamping: (edge ? 245 : gradientR + texture))
                pixels[index + 1] = UInt8(clamping: (edge ? 32 : gradientG + (block ? 24 : -24) + texture))
                pixels[index + 2] = UInt8(clamping: (edge ? 220 : gradientB - texture))
                pixels[index + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw NSError(domain: "JPEGFidelityFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create fixture image"])
        }

        let type: UTType = jpeg ? .jpeg : .png
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "JPEGFidelityFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create image destination"])
        }

        var properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "JPEG fidelity fixture"]
        ]
        if jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = 1.0
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "JPEGFidelityFixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode fixture image"])
        }
        return output as Data
    }
}
