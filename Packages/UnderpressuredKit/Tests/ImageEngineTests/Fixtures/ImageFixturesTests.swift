import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

private func source(_ data: Data) throws -> CGImageSource {
    try #require(CGImageSourceCreateWithData(data as CFData, nil))
}

private func properties(_ data: Data, index: Int = 0) throws -> [String: Any] {
    let src = try source(data)
    return try #require(CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any])
}

private func dictionary(_ props: [String: Any], _ key: CFString) -> [String: Any]? {
    props[key as String] as? [String: Any]
}

private func type(of data: Data) throws -> UTType? {
    CGImageSourceGetType(try source(data)).flatMap { UTType($0 as String) }
}

/// RGBA8 (non-premultiplied) pixel at (x, y) of the stored, unrotated image.
private func pixel(_ data: Data, x: Int, y: Int) throws -> [UInt8] {
    let image = try #require(CGImageSourceCreateImageAtIndex(try source(data), 0, [kCGImageSourceShouldCache: false] as CFDictionary))
    var out = [UInt8](repeating: 0, count: 4)
    let ctx = try #require(CGContext(
        data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setBlendMode(.copy)
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return out
}

@Suite struct ImageFixturesTests {
    @Test func cmykJPEG() throws {
        let data = try ImageFixtures.cmykJPEG(width: 64, height: 48)
        #expect(try type(of: data) == .jpeg)
        let props = try properties(data)
        #expect(props[kCGImagePropertyColorModel as String] as? String == "CMYK")
        #expect(props[kCGImagePropertyPixelWidth as String] as? Int == 64)
        #expect(props[kCGImagePropertyPixelHeight as String] as? Int == 48)
        #expect(try CGImageSourceCreateImageAtIndex(source(data), 0, nil) != nil)
    }

    @Test func png16() throws {
        let data = try ImageFixtures.png16()
        #expect(try type(of: data) == .png)
        let props = try properties(data)
        #expect(props[kCGImagePropertyDepth as String] as? Int == 16)
        #expect(props[kCGImagePropertyColorModel as String] as? String == "RGB")
        #expect(props[kCGImagePropertyHasAlpha as String] as? Bool != true)
    }

    @Test func grayscalePNG() throws {
        let props = try properties(ImageFixtures.grayscalePNG())
        #expect(props[kCGImagePropertyColorModel as String] as? String == "Gray")
        #expect(props[kCGImagePropertyDepth as String] as? Int == 8)
    }

    @Test func grayscaleJPEG() throws {
        let data = try ImageFixtures.grayscaleJPEG()
        #expect(try type(of: data) == .jpeg)
        #expect(try properties(data)[kCGImagePropertyColorModel as String] as? String == "Gray")
    }

    @Test func rgbaPNG() throws {
        let width = 64
        let data = try ImageFixtures.rgbaPNG(width: width, height: 48)
        let props = try properties(data)
        #expect(props[kCGImagePropertyHasAlpha as String] as? Bool == true)
        #expect(props[kCGImagePropertyColorModel as String] as? String == "RGB")
        let boundary = ImageFixtures.rgbaPNGOpaqueBoundary(width: width)
        #expect(try pixel(data, x: 0, y: 0)[3] == 255)
        #expect(try pixel(data, x: boundary - 1, y: 47)[3] == 255)
        #expect(try pixel(data, x: boundary, y: 0)[3] == 0)
        #expect(try pixel(data, x: width - 1, y: 47)[3] == 0)
    }

    @Test(arguments: 1...8)
    func orientation(tag: Int) throws {
        let data = try ImageFixtures.jpeg(orientation: tag, width: 40, height: 20)
        let props = try properties(data)
        #expect(props[kCGImagePropertyOrientation as String] as? Int == tag)
        // Stored pixels are never rotated.
        #expect(props[kCGImagePropertyPixelWidth as String] as? Int == 40)
        #expect(props[kCGImagePropertyPixelHeight as String] as? Int == 20)
        let red = try pixel(data, x: 2, y: 2)
        let green = try pixel(data, x: 37, y: 2)
        #expect(red[0] > 200 && red[1] < 60 && red[2] < 60)
        #expect(green[1] > 200 && green[0] < 60 && green[2] < 60)
        let bottomLeft = try pixel(data, x: 2, y: 17)
        #expect(!(bottomLeft[0] > 200 && bottomLeft[1] < 60))
    }

    @Test func orientationRejectsOutOfRange() {
        #expect(throws: ImageFixtures.GenerationError.self) { try ImageFixtures.jpeg(orientation: 9) }
        #expect(throws: ImageFixtures.GenerationError.self) { try ImageFixtures.jpeg(orientation: 0) }
    }

    @Test func displayP3JPEG() throws {
        let data = try ImageFixtures.displayP3JPEG()
        let props = try properties(data)
        #expect(props[kCGImagePropertyProfileName as String] as? String == "Display P3")
        #expect(props[kCGImagePropertyColorModel as String] as? String == "RGB")
    }

    @Test func displayP3PNG() throws {
        let props = try properties(ImageFixtures.displayP3PNG())
        #expect(props[kCGImagePropertyProfileName as String] as? String == "Display P3")
    }

    @Test func rgbJPEGAndPNGCarrySRGBProfile() throws {
        let jpeg = try properties(ImageFixtures.rgbJPEG())
        let png = try properties(ImageFixtures.rgbPNG())
        #expect(jpeg[kCGImagePropertyProfileName as String] as? String == "sRGB IEC61966-2.1")
        #expect(png[kCGImagePropertyProfileName as String] as? String == "sRGB IEC61966-2.1")
    }

    @Test func jpegWithAllMetadata() throws {
        let data = try ImageFixtures.jpegWithAllMetadata()
        let props = try properties(data)
        let tiff = try #require(dictionary(props, kCGImagePropertyTIFFDictionary))
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == ImageFixtures.Metadata.cameraMake)
        #expect(tiff[kCGImagePropertyTIFFModel as String] as? String == ImageFixtures.Metadata.cameraModel)
        let exif = try #require(dictionary(props, kCGImagePropertyExifDictionary))
        #expect(exif[kCGImagePropertyExifUserComment as String] as? String == ImageFixtures.Metadata.exifUserComment)
        let gps = try #require(dictionary(props, kCGImagePropertyGPSDictionary))
        #expect(gps[kCGImagePropertyGPSLatitude as String] as? Double == ImageFixtures.Metadata.gpsLatitude)
        #expect(gps[kCGImagePropertyGPSLongitude as String] as? Double == ImageFixtures.Metadata.gpsLongitude)
        let iptc = try #require(dictionary(props, kCGImagePropertyIPTCDictionary))
        #expect(iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String == ImageFixtures.Metadata.iptcCaption)
        #expect(iptc[kCGImagePropertyIPTCKeywords as String] as? [String] == ImageFixtures.Metadata.iptcKeywords)

        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(try source(data), 0, nil))
        let creator = try #require(CGImageMetadataCopyTagWithPath(metadata, nil, "dc:creator" as CFString))
        let items = try #require(CGImageMetadataTagCopyValue(creator) as? [Any])
        let values = items.map { item -> String? in
            if let string = item as? String { return string }
            return CGImageMetadataTagCopyValue(item as! CGImageMetadataTag) as? String
        }
        #expect(values == [ImageFixtures.Metadata.xmpCreator])
    }

    @Test func jpegWithGainMap() throws {
        let data = try ImageFixtures.jpegWithGainMap(width: 96, height: 64)
        #expect(try type(of: data) == .jpeg)
        let src = try source(data)
        let info = try #require(CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) as? [String: Any])
        let description = try #require(info[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any])
        #expect(description["Width"] as? Int == 96 / ImageFixtures.gainMapScale)
        #expect(description["Height"] as? Int == 64 / ImageFixtures.gainMapScale)
        #expect((info[kCGImageAuxiliaryDataInfoData as String] as? Data)?.isEmpty == false)
    }

    @Test func animatedGIF() throws {
        let data = try ImageFixtures.animatedGIF(frames: 5)
        #expect(try type(of: data) == .gif)
        let src = try source(data)
        #expect(CGImageSourceGetCount(src) == 5)
        let frame = try #require(dictionary(try properties(data, index: 1), kCGImagePropertyGIFDictionary))
        #expect(frame[kCGImagePropertyGIFDelayTime as String] as? Double == 0.1)
    }

    @Test func multiPageTIFF() throws {
        let data = try ImageFixtures.multiPageTIFF(pages: 3, width: 48, height: 32)
        #expect(try type(of: data) == .tiff)
        let src = try source(data)
        #expect(CGImageSourceGetCount(src) == 3)
        for page in 0..<3 {
            #expect(try properties(data, index: page)[kCGImagePropertyPixelWidth as String] as? Int == 48 + 8 * page)
        }
    }

    @Test func writeCreatesFolderAndFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fixtures-\(UUID().uuidString)/nested")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let data = try ImageFixtures.rgbPNG()
        let url = try ImageFixtures.write(data, named: "a.png", in: folder)
        #expect(url.lastPathComponent == "a.png")
        #expect(try Data(contentsOf: url) == data)
    }
}
