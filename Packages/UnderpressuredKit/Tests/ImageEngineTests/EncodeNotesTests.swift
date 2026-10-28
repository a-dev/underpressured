import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UnderpressuredCore
@testable import ImageEngine

/// 4.7: every §7.4 encode path sets exactly the notes the spec names, with and without an HDR gain map.
/// Notes are structured outcome values; presentation wording is tested in AppModelTests.
@Suite struct EncodeNotesTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let path: EncodePath
        let gainMap: Bool
        let source: Source
        let expected: Set<Note>

        var testDescription: String { "\(path) gainMap=\(gainMap) \(source)" }
    }

    /// `.png` is a photo-like gradient the palette can't reach the floor with; `.flatPNG` has few colors,
    /// so a palette is accepted.
    enum Source: Sendable, CustomStringConvertible {
        case jpeg
        case png
        case flatPNG

        var description: String {
            switch self {
            case .jpeg: "jpeg"
            case .png: "png"
            case .flatPNG: "flat png"
            }
        }
    }

    static let rows: [Row] = [
        Row(path: .jpegLossy, gainMap: false, source: .jpeg, expected: []),
        Row(path: .jpegLossy, gainMap: true, source: .jpeg, expected: [.hdrRemoved]),
        Row(path: .jpegLosslessRewrite, gainMap: false, source: .jpeg, expected: []),
        Row(path: .jpegLosslessRewrite, gainMap: true, source: .jpeg, expected: [.hdrRemoved]),
        Row(path: .jpegVisuallyLossless, gainMap: false, source: .jpeg, expected: [.reencodedVisuallyLossless]),
        Row(path: .jpegVisuallyLossless, gainMap: true, source: .jpeg,
            expected: [.hdrRemoved, .reencodedVisuallyLossless]),
        Row(path: .pngPalette, gainMap: false, source: .png, expected: [.keptFullColor]),
        Row(path: .pngPalette, gainMap: false, source: .flatPNG, expected: []),
        Row(path: .pngPalette, gainMap: true, source: .jpeg, expected: [.keptFullColor, .hdrRemoved]),
        Row(path: .pngLossless, gainMap: false, source: .png, expected: []),
        Row(path: .pngLossless, gainMap: true, source: .jpeg, expected: [.hdrRemoved]),
    ]

    private func decoded(_ row: Row) throws -> DecodedImage {
        let data: Data
        switch (row.source, row.gainMap) {
        case (.jpeg, false): data = try ImageFixtures.rgbJPEG()
        case (.jpeg, true): data = try ImageFixtures.jpegWithGainMap()
        case (.png, _): data = try ImageFixtures.rgbPNG()
        case (.flatPNG, _): data = try flatPNG()
        }
        var image = try Decode.decode(data)
        // A visually lossless encode is the JPEG re-encode of pixels that no longer match the source file.
        if row.path == .jpegVisuallyLossless { image.pixelsTransformed = true }
        return image
    }

    /// PNG of UI-like blocks with nearby shades (128 x 96), so quantization reduces the final size.
    private func flatPNG(width: Int = 128, height: Int = 96) throws -> Data {
        let colors: [(UInt8, UInt8, UInt8)] = [(240, 240, 240), (30, 120, 220), (20, 20, 20), (250, 200, 40)]
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = colors[(x / 32 + y / 24) % colors.count]
                let i = (y * width + x) * 4
                pixels[i] = c.0 - UInt8((x + y) % 8)
                pixels[i + 1] = c.1
                pixels[i + 2] = c.2
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func plan(_ path: EncodePath) -> EncodePlan {
        switch path {
        case .jpegLossy: EncodePlan(format: .jpeg, quality: 75, lossless: false, keepMetadata: false)
        case .jpegLosslessRewrite, .jpegVisuallyLossless: EncodePlan(format: .jpeg, quality: 75, lossless: true, keepMetadata: false)
        case .pngPalette: EncodePlan(format: .png, quality: 75, lossless: false, keepMetadata: false)
        case .pngLossless: EncodePlan(format: .png, quality: 100, lossless: true, keepMetadata: false)
        }
    }

    @Test(arguments: rows)
    func notesMatchSpec(_ row: Row) throws {
        let image = try decoded(row)
        #expect(image.facts.hasGainMap == row.gainMap)
        let out = try NativeCodec.encode(row.path, image, plan(row.path))

        #expect(out.notes.count == row.expected.count, "duplicate or missing notes: \(out.notes)")
        #expect(Set(out.notes) == row.expected)
    }
}
