import UnderpressuredApplication
import Foundation
import Synchronization
import Testing
import UnderpressuredCore
@testable import ImageEngine

/// 4.6: encode-path selection (§7.4), one test per cell of the table, and the ImageIO fallback.
@Suite struct EncodePathTests {
    private static let codec = ImageIOCodec()

    private func decode(_ data: Data, resized: Bool = false) async throws -> DecodedImage {
        let image = try await Self.codec.decode(data)
        guard resized else { return image }
        return try await Self.codec.transform(image, TransformPlan(resizeRule: .maxLongEdge(32), flattenOntoWhite: false))
    }

    private func plan(_ format: WritableFormat, quality: Int = 80, lossless: Bool = false) -> EncodePlan {
        EncodePlan(format: format, quality: Quality.clamping(quality), lossless: lossless, keepMetadata: false)
    }

    private func select(_ plan: EncodePlan, _ image: DecodedImage) -> EncodePath {
        EncodePath.select(plan, image)
    }

    // MARK: JPEG from a JPEG source, no resize

    @Test func jpegFromJPEGNotResizedLosslessOffIsLossy() async throws {
        let image = try await decode(ImageFixtures.rgbJPEG())
        #expect(image.pixelsTransformed == false)
        #expect(select(plan(.jpeg), image) == .jpegLossy)
    }

    @Test func jpegFromJPEGNotResizedLosslessOnIsRewrite() async throws {
        let image = try await decode(ImageFixtures.rgbJPEG())
        #expect(select(plan(.jpeg, lossless: true), image) == .jpegLosslessRewrite)
    }

    @Test func resizeRuleThatDoesNotShrinkKeepsTheRewrite() async throws {
        let source = try await decode(ImageFixtures.rgbJPEG())
        let image = try await Self.codec.transform(source, TransformPlan(resizeRule: .maxLongEdge(10_000), flattenOntoWhite: false))
        #expect(image.pixelsTransformed == false)
        #expect(select(plan(.jpeg, lossless: true), image) == .jpegLosslessRewrite)
    }

    // MARK: JPEG that must be re-encoded

    @Test func jpegFromResizedJPEGLosslessOffIsLossy() async throws {
        let image = try await decode(ImageFixtures.rgbJPEG(), resized: true)
        #expect(image.pixelsTransformed)
        #expect(select(plan(.jpeg), image) == .jpegLossy)
    }

    @Test func jpegFromResizedJPEGLosslessOnIsVisuallyLossless() async throws {
        let image = try await decode(ImageFixtures.rgbJPEG(), resized: true)
        #expect(select(plan(.jpeg, lossless: true), image) == .jpegVisuallyLossless)
    }

    @Test func jpegFromPNGLosslessOffIsLossy() async throws {
        let image = try await decode(ImageFixtures.rgbPNG())
        #expect(image.facts.format == .png)
        #expect(select(plan(.jpeg), image) == .jpegLossy)
    }

    @Test func jpegFromPNGLosslessOnIsVisuallyLossless() async throws {
        let image = try await decode(ImageFixtures.rgbPNG())
        #expect(select(plan(.jpeg, lossless: true), image) == .jpegVisuallyLossless)
    }

    @Test func flattenedPNGWithAlphaToJPEGLosslessOnIsVisuallyLossless() async throws {
        let source = try await decode(ImageFixtures.rgbaPNG())
        let image = try await Self.codec.transform(source, TransformPlan(resizeRule: .none, flattenOntoWhite: true))
        #expect(select(plan(.jpeg, lossless: true), image) == .jpegVisuallyLossless)
    }

    // MARK: PNG output

    @Test func pngFromPNGBelowThresholdLosslessOffIsPalette() async throws {
        let image = try await decode(ImageFixtures.rgbPNG())
        #expect(select(plan(.png, quality: PNGPalette.losslessQuality - 1), image) == .pngPalette)
        #expect(select(plan(.png, quality: 0), image) == .pngPalette)
    }

    @Test func pngFromPNGAtOrAboveThresholdIsLossless() async throws {
        let image = try await decode(ImageFixtures.rgbPNG())
        #expect(PNGPalette.losslessQuality == 98)
        #expect(select(plan(.png, quality: PNGPalette.losslessQuality), image) == .pngLossless)
        #expect(select(plan(.png, quality: 100), image) == .pngLossless)
    }

    @Test func pngLosslessOnIsLosslessAtAnyQuality() async throws {
        let image = try await decode(ImageFixtures.rgbPNG())
        for quality in [0, 50, 97, 98, 100] {
            #expect(select(plan(.png, quality: quality, lossless: true), image) == .pngLossless)
        }
    }

    @Test func pngFromJPEGSourceFollowsThePNGRows() async throws {
        let image = try await decode(ImageFixtures.rgbJPEG())
        #expect(select(plan(.png), image) == .pngPalette)
        #expect(select(plan(.png, lossless: true), image) == .pngLossless)
    }

    @Test func pngFromResizedPNGFollowsThePNGRows() async throws {
        let image = try await decode(ImageFixtures.rgbPNG(), resized: true)
        #expect(image.pixelsTransformed)
        #expect(select(plan(.png), image) == .pngPalette)
        #expect(select(plan(.png, lossless: true), image) == .pngLossless)
    }

    // MARK: Fallback

    @Test func eligibleFallbacksPreserveTheirContracts() async throws {
        let attempts = Mutex<[EncodePath]>([])
        let codec = NativeCodec(native: { path, _, _ throws(CodecError) in
            attempts.withLock { $0.append(path) }
            throw .encodeFailed("injected")
        })
        let image = try await codec.decode(ImageFixtures.rgbaPNG(width: 96, height: 64))

        for (format, lossless, expected) in [
            (WritableFormat.jpeg, false, EncodePath.jpegLossy),
            (.png, false, .pngPalette),
            (.png, true, .pngLossless),
        ] {
            attempts.withLock { $0.removeAll() }
            let settings = plan(format, quality: 50, lossless: lossless)
            let output = try await codec.encode(image, settings)
            let reference = try Encode.encode(image, settings)

            #expect(attempts.withLock { $0 } == [expected])
            // JPEG must honor the chosen lossy quality; PNG must preserve full-color pixels.
            #expect(output.data == reference.data)
            #expect(output.notes == reference.notes + (expected == .pngPalette ? [.keptFullColor] : []))
            #expect(!output.notes.contains(.reencodedVisuallyLossless))
            if format == .png {
                let decoded = try await codec.decode(output.data)
                let before = try PixelBuffer.render(image.pixels, layout: .rgba8, sourceProfile: nil)
                let after = try PixelBuffer.render(decoded.pixels, layout: .rgba8, sourceProfile: nil)
                #expect(before.bytes == after.bytes)
                #expect(after.hasTransparency)
            }
        }
    }

    @Test(arguments: [0, 50, 100])
    func strongerJPEGContractsRejectFallbackAtEveryStoredQuality(quality: Int) async throws {
        let attempts = Mutex<[EncodePath]>([])
        let codec = NativeCodec(native: { path, _, _ throws(CodecError) in
            attempts.withLock { $0.append(path) }
            throw .encodeFailed("injected")
        })
        let source = try ImageFixtures.rgbJPEG(width: 96, height: 64)
        let original = try await codec.decode(source)
        let resized = try await codec.transform(
            original, TransformPlan(resizeRule: .maxLongEdge(32), flattenOntoWhite: false))
        let converted = try await codec.decode(ImageFixtures.rgbPNG())
        for (image, expected) in [
            (original, EncodePath.jpegLosslessRewrite),
            (resized, .jpegVisuallyLossless),
            (converted, .jpegVisuallyLossless),
        ] {
            attempts.withLock { $0.removeAll() }
            await #expect(throws: CodecError.losslessEncoderUnavailable) {
                try await codec.encode(image, plan(.jpeg, quality: quality, lossless: true))
            }
            #expect(attempts.withLock { $0 } == [expected])
        }
        #expect(original.sourceData == source)
    }

    @Test func workingNativeEncoderResultIsReturnedUnchanged() async throws {
        let marker = EncodedImage(data: Data([1, 2, 3]), format: .jpeg, pixelWidth: 1, pixelHeight: 1)
        let codec = NativeCodec(native: { _, _, _ throws(CodecError) in marker })
        let image = try await codec.decode(ImageFixtures.rgbJPEG())
        let output = try await codec.encode(image, plan(.jpeg))
        #expect(output == marker)
    }
}
