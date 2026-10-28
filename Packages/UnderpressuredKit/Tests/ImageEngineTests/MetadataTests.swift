import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UnderpressuredCore
@testable import ImageEngine

private struct Output {
    let notes: [Note]
    let source: CGImageSource
    let properties: [String: Any]

    func group(_ key: CFString) -> [String: Any]? { properties[key as String] as? [String: Any] }

    func xmpValue(_ path: String) -> String? {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
            let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString)
        else { return nil }
        return CGImageMetadataTagCopyValue(tag) as? String
    }

    var hasGainMap: Bool {
        CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }

    /// The embedded ICC profile of the decoded output.
    var icc: Data? { CGImageSourceCreateImageAtIndex(source, 0, nil)?.colorSpace?.copyICCData() as Data? }
}

private func write(_ image: DecodedImage, type: UTType = .jpeg, keep: Bool) throws -> Output {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    let notes = Metadata.addImage(image, to: destination, encodeOptions: [:], keepMetadata: keep)
    #expect(CGImageDestinationFinalize(destination))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    return Output(notes: notes, source: source, properties: properties)
}

private func decoded(_ data: Data) throws -> DecodedImage { try Decode.decode(data) }

/// A decoded image whose EXIF/TIFF and XMP orientation both say 6, as a rotated source would.
private func rotatedWithMetadata() throws -> DecodedImage {
    var image = try decoded(ImageFixtures.jpegWithAllMetadata())
    image.metadata.properties[kCGImagePropertyOrientation] = 6
    var tiff = image.metadata.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    tiff[kCGImagePropertyTIFFOrientation] = 6
    image.metadata.properties[kCGImagePropertyTIFFDictionary] = tiff
    let xmp = try #require(image.metadata.xmp.flatMap { CGImageMetadataCreateMutableCopy($0) })
    #expect(CGImageMetadataSetValueWithPath(xmp, nil, "tiff:Orientation" as CFString, "6" as CFString))
    image.metadata.xmp = xmp
    return image
}

@Suite struct MetadataTests {
    @Test func metadata_spec7_3_keepOffStripsEverythingButICC() throws {
        let image = try decoded(ImageFixtures.jpegWithAllMetadata())
        let out = try write(image, keep: false)
        let exif = out.group(kCGImagePropertyExifDictionary)
        #expect(exif?[kCGImagePropertyExifUserComment as String] == nil)
        #expect(out.group(kCGImagePropertyGPSDictionary) == nil)
        #expect(out.group(kCGImagePropertyIPTCDictionary) == nil)
        let tiff = out.group(kCGImagePropertyTIFFDictionary)
        #expect(tiff?[kCGImagePropertyTIFFMake as String] == nil)
        #expect(tiff?[kCGImagePropertyTIFFModel as String] == nil)
        #expect(out.xmpValue("dc:creator") == nil)
        #expect(out.icc == image.facts.iccProfile)
        #expect(out.icc != nil)
    }

    @Test func metadata_spec7_3_keepOnKeepsEXIFXMPIPTCGPS() throws {
        let image = try decoded(ImageFixtures.jpegWithAllMetadata())
        let out = try write(image, keep: true)
        let exif = try #require(out.group(kCGImagePropertyExifDictionary))
        #expect(exif[kCGImagePropertyExifUserComment as String] as? String == ImageFixtures.Metadata.exifUserComment)
        let tiff = try #require(out.group(kCGImagePropertyTIFFDictionary))
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == ImageFixtures.Metadata.cameraMake)
        let gps = try #require(out.group(kCGImagePropertyGPSDictionary))
        #expect(abs((gps[kCGImagePropertyGPSLatitude as String] as? Double ?? 0) - ImageFixtures.Metadata.gpsLatitude) < 0.001)
        #expect(abs((gps[kCGImagePropertyGPSLongitude as String] as? Double ?? 0) - ImageFixtures.Metadata.gpsLongitude) < 0.001)
        let iptc = try #require(out.group(kCGImagePropertyIPTCDictionary))
        #expect(iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String == ImageFixtures.Metadata.iptcCaption)
        #expect(iptc[kCGImagePropertyIPTCKeywords as String] as? [String] == ImageFixtures.Metadata.iptcKeywords)
        #expect(out.xmpValue("dc:creator[0]") == ImageFixtures.Metadata.xmpCreator)
        #expect(out.icc == image.facts.iccProfile)
    }

    @Test func metadata_spec7_3_keepOnResetsOrientationToOne() throws {
        let out = try write(try rotatedWithMetadata(), keep: true)
        #expect(out.properties[kCGImagePropertyOrientation as String] as? Int == 1)
        #expect(out.group(kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFOrientation as String] as? Int == 1)
        #expect(out.xmpValue("tiff:Orientation") == "1")
    }

    @Test func metadata_spec7_3_keepOffHasNoRotatedOrientation() throws {
        let out = try write(try rotatedWithMetadata(), keep: false)
        let orientation = out.properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        #expect(orientation == 1)
        let tiffOrientation = out.group(kCGImagePropertyTIFFDictionary)?[kCGImagePropertyTIFFOrientation as String] as? Int ?? 1
        #expect(tiffOrientation == 1)
        #expect((out.xmpValue("tiff:Orientation") ?? "1") == "1")
    }

    @Test(arguments: [true, false])
    func metadata_spec7_3_gainMapIsNeverWritten(keep: Bool) throws {
        let image = try decoded(ImageFixtures.jpegWithGainMap())
        #expect(image.facts.hasGainMap)
        let out = try write(image, keep: keep)
        #expect(!out.hasGainMap)
        #expect(out.notes == [.hdrRemoved])
    }

    @Test func metadata_spec7_3_noGainMapNoNote() throws {
        let out = try write(try decoded(ImageFixtures.jpegWithAllMetadata()), keep: true)
        #expect(out.notes.isEmpty)
    }

    @Test func metadata_spec7_3_iccAlwaysEmbedded_displayP3() throws {
        let image = try decoded(ImageFixtures.displayP3JPEG())
        for keep in [true, false] {
            let out = try write(image, keep: keep)
            #expect(out.icc == image.facts.iccProfile)
        }
    }

    @Test func metadata_spec7_3_keepOnWorksForPNG() throws {
        let out = try write(try decoded(ImageFixtures.rgbPNG()), type: .png, keep: true)
        #expect(out.icc != nil)
    }
}
