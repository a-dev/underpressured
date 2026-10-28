import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates small encoded image files in memory, for tests that need a specific kind of input.
/// Nothing here is committed as a binary: every fixture is drawn with CoreGraphics and encoded with ImageIO.
/// All images are at most 256 px on a side and contain gradients, so encoders behave as they do on photos.
enum ImageFixtures {
    struct GenerationError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Orientation marker

    /// Side, in stored pixels, of the corner markers in `jpeg(orientation:width:height:)`.
    static let markerSize = 8

    // MARK: RGBA layout

    /// Pixels of `rgbaPNG(width:height:)` with x < `rgbaPNGOpaqueBoundary` are fully opaque.
    /// The rest (x >= boundary) are fully transparent (alpha 0). The width must be at least 2.
    static func rgbaPNGOpaqueBoundary(width: Int) -> Int { width / 2 }

    // MARK: Gain map layout

    /// Size of the gain map image in `jpegWithGainMap()`, relative to the base image (half in each direction).
    static let gainMapScale = 2

    // MARK: Color model fixtures

    /// 8-bit CMYK JPEG (Generic CMYK colour space, ColorModel "CMYK").
    static func cmykJPEG(width: Int = 64, height: Int = 48) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(x * 255 / max(width - 1, 1))
                bytes[i + 1] = UInt8(y * 255 / max(height - 1, 1))
                bytes[i + 2] = UInt8(((x + y) * 255 / max(width + height - 2, 1)))
                bytes[i + 3] = 20
            }
        }
        let image = try makeImage(
            width: width, height: height, bitsPerComponent: 8, components: 4,
            space: try colorSpace(CGColorSpace.genericCMYK), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            bytes: bytes)
        return try encode([image], type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
    }

    /// 16-bit-per-channel RGB PNG (sRGB, no alpha, Depth 16).
    static func png16(width: Int = 64, height: Int = 48) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 8)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 8
                let r = UInt16(x * 65535 / max(width - 1, 1))
                let g = UInt16(y * 65535 / max(height - 1, 1))
                let b = UInt16((x + y) * 65535 / max(width + height - 2, 1))
                for (c, v) in [r, g, b, 0].enumerated() {
                    bytes[i + c * 2] = UInt8(v >> 8)
                    bytes[i + c * 2 + 1] = UInt8(v & 0xFF)
                }
            }
        }
        let image = try makeImage(
            width: width, height: height, bitsPerComponent: 16, components: 4,
            space: try colorSpace(CGColorSpace.sRGB),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Big.rawValue),
            bytes: bytes)
        return try encode([image], type: .png)
    }

    /// 8-bit grayscale PNG (Gray colour space, ColorModel "Gray").
    static func grayscalePNG(width: Int = 64, height: Int = 48) throws -> Data {
        try encode([try grayImage(width: width, height: height)], type: .png)
    }

    /// 8-bit grayscale JPEG (Gray colour space, ColorModel "Gray").
    static func grayscaleJPEG(width: Int = 64, height: Int = 48) throws -> Data {
        try encode([try grayImage(width: width, height: height)], type: .jpeg,
                   properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
    }

    /// 8-bit sRGB PNG with an alpha channel. Pixels with x < `rgbaPNGOpaqueBoundary(width:)` are opaque
    /// (alpha 255) and carry a colour gradient; the others are fully transparent (alpha 0).
    static func rgbaPNG(width: Int = 64, height: Int = 48) throws -> Data {
        let boundary = rgbaPNGOpaqueBoundary(width: width)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<boundary {
                let i = (y * width + x) * 4
                // Premultiplied, and alpha is 255, so the colour is stored unchanged.
                bytes[i] = UInt8(x * 255 / max(width - 1, 1))
                bytes[i + 1] = UInt8(y * 255 / max(height - 1, 1))
                bytes[i + 2] = 128
                bytes[i + 3] = 255
            }
        }
        let image = try makeImage(
            width: width, height: height, bitsPerComponent: 8, components: 4,
            space: try colorSpace(CGColorSpace.sRGB),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            bytes: bytes)
        return try encode([image], type: .png)
    }

    // MARK: Photo-like RGB fixtures

    /// Plain sRGB photo-like JPEG with an embedded sRGB profile.
    static func rgbJPEG(width: Int = 96, height: Int = 64) throws -> Data {
        try encode([try rgbImage(width: width, height: height, space: colorSpace(CGColorSpace.sRGB))],
                   type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
    }

    /// Plain sRGB photo-like PNG with an embedded sRGB profile.
    static func rgbPNG(width: Int = 96, height: Int = 64) throws -> Data {
        try encode([try rgbImage(width: width, height: height, space: colorSpace(CGColorSpace.sRGB))], type: .png)
    }

    /// JPEG with an embedded Display P3 ICC profile (profile name "Display P3").
    static func displayP3JPEG(width: Int = 96, height: Int = 64) throws -> Data {
        try encode([try rgbImage(width: width, height: height, space: colorSpace(CGColorSpace.displayP3))],
                   type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
    }

    /// PNG with an embedded Display P3 ICC profile.
    static func displayP3PNG(width: Int = 96, height: Int = 64) throws -> Data {
        try encode([try rgbImage(width: width, height: height, space: colorSpace(CGColorSpace.displayP3))], type: .png)
    }

    // MARK: Orientation

    /// JPEG whose stored pixels are `width` x `height` (default 40x20, so orientations 5...8 change the
    /// displayed shape) and whose EXIF orientation tag is `orientation` (1...8). The pixels are never rotated.
    ///
    /// Stored-pixel markers: a red block (255, 0, 0) of `markerSize` px at the top-left corner and a green
    /// block (0, 255, 0) at the top-right corner. Everything else is a blue/grey gradient. Two markers
    /// make all 8 orientations distinguishable once the image is displayed.
    static func jpeg(orientation: Int, width: Int = 40, height: Int = 20) throws -> Data {
        guard (1...8).contains(orientation) else { throw GenerationError(description: "orientation \(orientation) not in 1...8") }
        precondition(width >= 2 * markerSize && height >= markerSize)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                var rgb: (UInt8, UInt8, UInt8) = (UInt8(60 + x * 60 / width), UInt8(60 + y * 60 / height), UInt8(140 + (x + y) * 60 / (width + height)))
                if y < markerSize && x < markerSize { rgb = (255, 0, 0) }
                if y < markerSize && x >= width - markerSize { rgb = (0, 255, 0) }
                bytes[i] = rgb.0
                bytes[i + 1] = rgb.1
                bytes[i + 2] = rgb.2
            }
        }
        let image = try makeImage(
            width: width, height: height, bitsPerComponent: 8, components: 4,
            space: try colorSpace(CGColorSpace.sRGB),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), bytes: bytes)
        return try encode([image], type: .jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: orientation
        ])
    }

    // MARK: Metadata

    /// Values written by `jpegWithAllMetadata()`, for tests to compare against.
    enum Metadata {
        static let cameraMake = "Underpressured Test Camera"
        static let cameraModel = "Fixture 1"
        static let exifUserComment = "fixture-comment"
        static let gpsLatitude = 52.5
        static let gpsLongitude = 13.4
        static let iptcCaption = "Fixture caption"
        static let iptcKeywords = ["fixture", "metadata"]
        static let xmpCreator = "Fixture Author"
    }

    /// sRGB JPEG with EXIF (make, model, user comment), GPS (52.5 N, 13.4 E), IPTC (caption, keywords)
    /// and XMP (dc:creator) metadata. Values are in `Metadata`.
    static func jpegWithAllMetadata(width: Int = 96, height: Int = 64) throws -> Data {
        let image = try rgbImage(width: width, height: height, space: colorSpace(CGColorSpace.sRGB))
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: Metadata.cameraMake,
                kCGImagePropertyTIFFModel: Metadata.cameraModel
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: Metadata.exifUserComment
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: Metadata.gpsLatitude,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: Metadata.gpsLongitude,
                kCGImagePropertyGPSLongitudeRef: "E"
            ],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCaptionAbstract: Metadata.iptcCaption,
                kCGImagePropertyIPTCKeywords: Metadata.iptcKeywords
            ]
        ]
        let withProperties = try encode([image], type: .jpeg, properties: properties)

        // Second pass: copy the compressed image and add XMP, without re-encoding the pixels.
        let xmp = CGImageMetadataCreateMutable()
        let tag = CGImageMetadataTagCreate(
            kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore, "creator" as CFString,
            .arrayOrdered, [Metadata.xmpCreator] as CFArray)
        guard let tag, CGImageMetadataSetTagWithPath(xmp, nil, "dc:creator" as CFString, tag),
              let source = CGImageSourceCreateWithData(withProperties as CFData, nil)
        else { throw GenerationError(description: "cannot build XMP metadata") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw GenerationError(description: "cannot create JPEG destination")
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: xmp,
            kCGImageDestinationMergeMetadata: true
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) else {
            throw GenerationError(description: "XMP copy failed: \(String(describing: error?.takeRetainedValue()))")
        }
        return out as Data
    }

    // MARK: Gain map

    /// JPEG with an auxiliary HDR gain map (`kCGImageAuxiliaryDataTypeHDRGainMap`): a half-size 8-bit
    /// grayscale gradient. Read it back with `CGImageSourceCopyAuxiliaryDataInfoAtIndex`.
    static func jpegWithGainMap(width: Int = 96, height: Int = 64) throws -> Data {
        let base = try rgbImage(width: width, height: height, space: colorSpace(CGColorSpace.displayP3))
        let gw = width / gainMapScale
        let gh = height / gainMapScale
        var map = [UInt8](repeating: 0, count: gw * gh)
        for y in 0..<gh { for x in 0..<gw { map[y * gw + x] = UInt8(x * 255 / max(gw - 1, 1)) } }

        let metadata = CGImageMetadataCreateMutable()
        let ns = "http://ns.apple.com/HDRGainMap/1.0/" as CFString
        CGImageMetadataRegisterNamespaceForPrefix(metadata, ns, "HDRGainMap" as CFString, nil)
        CGImageMetadataSetValueWithPath(metadata, nil, "HDRGainMap:HDRGainMapVersion" as CFString, 65536 as CFNumber)

        let info: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: Data(map) as CFData,
            kCGImageAuxiliaryDataInfoDataDescription: [
                "Width": gw, "Height": gh, "BytesPerRow": gw,
                "PixelFormat": 0x4C30_3038 // 'L008', one 8-bit component
            ],
            kCGImageAuxiliaryDataInfoMetadata: metadata
        ]
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw GenerationError(description: "cannot create JPEG destination")
        }
        CGImageDestinationAddImage(dest, base, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeHDRGainMap, info as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw GenerationError(description: "gain map JPEG finalize failed") }
        return out as Data
    }

    // MARK: Multi-frame

    /// Animated GIF with `frames` frames (default 4), each 32x32 with a different hue, looping forever.
    static func animatedGIF(frames: Int = 4, width: Int = 32, height: Int = 32) throws -> Data {
        precondition(frames >= 1)
        var images: [CGImage] = []
        for n in 0..<frames {
            let hue = Double(n) / Double(frames)
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let t = Double(x + y) / Double(width + height)
                    bytes[i] = UInt8(255 * (hue * (1 - t) + 0.2 * t))
                    bytes[i + 1] = UInt8(255 * (1 - hue) * (1 - t) + 40 * t)
                    bytes[i + 2] = UInt8(255 * t)
                }
            }
            images.append(try makeImage(
                width: width, height: height, bitsPerComponent: 8, components: 4,
                space: colorSpace(CGColorSpace.sRGB),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), bytes: bytes))
        }
        let frameProps: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]]
        return try encode(images, type: .gif,
                          fileProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
                          properties: frameProps)
    }

    /// Multi-page TIFF with `pages` pages (default 3). Page n is `width + 8n` px wide and `height` tall.
    static func multiPageTIFF(pages: Int = 3, width: Int = 48, height: Int = 32) throws -> Data {
        precondition(pages >= 1)
        let images = try (0..<pages).map { n in
            try rgbImage(width: width + 8 * n, height: height, space: colorSpace(CGColorSpace.sRGB), phase: n)
        }
        return try encode(images, type: .tiff)
    }

    // MARK: Files

    /// Writes `data` to `folder/name` and returns the file URL. The folder is created if missing.
    @discardableResult
    static func write(_ data: Data, named name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: url)
        return url
    }

    // MARK: Helpers

    private static func colorSpace(_ name: CFString) throws -> CGColorSpace {
        guard let space = CGColorSpace(name: name) else { throw GenerationError(description: "no colour space \(name)") }
        return space
    }

    private static func makeImage(
        width: Int, height: Int, bitsPerComponent: Int, components: Int, space: CGColorSpace,
        bitmapInfo: CGBitmapInfo, bytes: [UInt8]
    ) throws -> CGImage {
        let bitsPerPixel = bitsPerComponent * components
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel,
                bytesPerRow: width * bitsPerPixel / 8, space: space, bitmapInfo: bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw GenerationError(description: "cannot create CGImage \(width)x\(height)") }
        return image
    }

    private static func grayImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { bytes[y * width + x] = UInt8((x * 3 + y * 2) * 255 / (3 * width + 2 * height)) }
        }
        return try makeImage(
            width: width, height: height, bitsPerComponent: 8, components: 1,
            space: try colorSpace(CGColorSpace.genericGrayGamma2_2),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), bytes: bytes)
    }

    /// Opaque photo-like RGB image: two gradients plus a few soft circles, so it is not trivially compressible.
    private static func rgbImage(width: Int, height: Int, space: CGColorSpace, phase: Int = 0) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let dx = Double(x) - Double(width) / 2
                let dy = Double(y) - Double(height) / 2
                let ring = 0.5 + 0.5 * sin(sqrt(dx * dx + dy * dy) / 3 + Double(phase))
                bytes[i] = UInt8(40 + 150 * Double(x) / Double(width) * (0.6 + 0.4 * ring))
                bytes[i + 1] = UInt8(40 + 150 * Double(y) / Double(height))
                bytes[i + 2] = UInt8(60 + 120 * ring)
            }
        }
        return try makeImage(
            width: width, height: height, bitsPerComponent: 8, components: 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), bytes: bytes)
    }

    private static func encode(
        _ images: [CGImage], type: UTType, fileProperties: [CFString: Any]? = nil, properties: [CFString: Any]? = nil
    ) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, images.count, nil) else {
            throw GenerationError(description: "cannot create \(type.identifier) destination")
        }
        if let fileProperties { CGImageDestinationSetProperties(dest, fileProperties as CFDictionary) }
        for image in images { CGImageDestinationAddImage(dest, image, properties as CFDictionary?) }
        guard CGImageDestinationFinalize(dest) else { throw GenerationError(description: "\(type.identifier) finalize failed") }
        return out as Data
    }
}
