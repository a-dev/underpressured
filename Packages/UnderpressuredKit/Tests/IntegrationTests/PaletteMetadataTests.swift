import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UnderpressuredCore
@testable import ImageEngine

@Suite struct PaletteMetadataTests {
    /// Flat transparent pixels, stored sideways with identifiable metadata in every supported family.
    private func fixture(displayP3: Bool = false) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 512, height: 384, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 512, height: 384))
        for y in 0..<12 {
            for x in 0..<16 where (x + y) % 4 != 0 {
                let red = ((x + y) % 3 == 0 ? 0.85 : 0.05) + Double((x * 17 + y * 13) % 64) / 1024
                context.setFillColor(CGColor(red: red, green: 0.5, blue: 0.2, alpha: 1))
                context.fill(CGRect(x: x * 32, y: y * 32, width: 32, height: 32))
            }
        }
        let pixels = try #require(context.makeImage())
        let tree = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataSetValueWithPath(tree, nil, "xmp:Label" as CFString, "palette-xmp" as CFString))
        #expect(CGImageMetadataSetValueWithPath(tree, nil, "tiff:Orientation" as CFString, "6" as CFString))
        #expect(CGImageMetadataSetValueWithPath(tree, nil, "exif:PixelXDimension" as CFString, "512" as CFString))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: 6, kCGImagePropertyTIFFMake: "palette-camera"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "palette-exif"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.5, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "palette-iptc"]
        ]
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(dest, pixels, tree, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func verify(_ data: Data, keep: Bool, width: Int, height: Int, icc: Data?) throws {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let pixels = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(data[data.startIndex + 25] == 3)
        #expect(pixels.width == width && pixels.height == height)
        let decoded = try Decode.decode(data)
        #expect(icc != nil)
        #expect(decoded.facts.iccProfile == icc)
        #expect(try PixelBuffer.render(decoded.pixels, layout: .rgba8, sourceProfile: nil).hasTransparency)
        let props = decoded.metadata.properties
        func value(_ group: CFString, _ key: CFString) -> Any? { (props[group] as? [CFString: Any])?[key] }
        #expect(value(kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment) as? String == (keep ? "palette-exif" : nil))
        #expect(value(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude) as? Double == (keep ? 52.5 : nil))
        #expect(value(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract) as? String == (keep ? "palette-iptc" : nil))
        #expect(value(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFMake) as? String == (keep ? "palette-camera" : nil))
        func xmp(_ path: String) -> String? {
            guard let tree = decoded.metadata.xmp else { return nil }
            return CGImageMetadataCopyStringValueWithPath(tree, nil, path as CFString) as String?
        }
        #expect(xmp("xmp:Label") == (keep ? "palette-xmp" : nil))
        #expect((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect((xmp("tiff:Orientation") ?? "1") == "1")
        for (path, expected) in [("exif:PixelXDimension", width), ("exif:PixelYDimension", height)] {
            #expect((xmp(path).flatMap(Int.init) ?? expected) == expected)
        }
        for (key, expected) in [(kCGImagePropertyExifPixelXDimension, width), (kCGImagePropertyExifPixelYDimension, height)] {
            #expect((value(kCGImagePropertyExifDictionary, key) as? Int ?? expected) == expected)
        }
    }

    @Test(arguments: [true, false], [false, true])
    func nativeRoundTrip(keep: Bool, resize: Bool) async throws {
        let codec = NativeCodec()
        let input = try fixture(displayP3: true)
        let decoded = try await codec.decode(input)
        #expect(decoded.pixels.width == 384 && decoded.pixels.height == 512)
        let image = try await codec.transform(decoded, TransformPlan(resizeRule: resize ? .maxLongEdge(256) : .none, flattenOntoWhite: false))
        let plan = EncodePlan(format: .png, quality: 80, lossless: false, keepMetadata: keep)
        let output = try await codec.encode(image, plan)
        #expect(!output.notes.contains(.keptFullColor))
        try verify(output.data, keep: keep, width: resize ? 192 : 384, height: resize ? 256 : 512, icc: decoded.facts.iccProfile)
    }

    @Test(arguments: [true, false])
    func pipelineRoundTrip(keep: Bool) async throws {
        let harness = try EndToEndTests()
        defer { withExtendedLifetime(harness) {} }
        let source = harness.root.appendingPathComponent("palette.tiff")
        let input = try fixture()
        try input.write(to: source)
        let export = try harness.folder("export")
        #expect(try harness.files.attributes(of: export).kind == .directory)
        let settings = EffectiveSettings(quality: 80, lossless: false, resizeRule: .maxLongEdge(256), keepMetadata: keep)
        let outcomes = await harness.run([source], settings: settings, format: .png, destination: .exportFolder(export))
        let output = export.appendingPathComponent("palette.png")
        guard case .optimized(_, let notes, let url) = try #require(outcomes.first) else {
            Issue.record("Expected optimized palette output: \(outcomes)"); return
        }
        #expect(url == output)
        #expect(!notes.contains(.keptFullColor))
        try verify(Data(contentsOf: output), keep: keep, width: 192, height: 256, icc: Decode.decode(input).facts.iccProfile)
        #expect(try Data(contentsOf: source) == input)
    }
}
