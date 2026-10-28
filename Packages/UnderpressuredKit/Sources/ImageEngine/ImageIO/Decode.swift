import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UnderpressuredCore

/// Decodes images with ImageIO.
enum Decode {
    /// Format, displayed pixel size (orientation applied) and frame count, without decoding pixels.
    static func inspect(_ data: Data) throws(CodecError) -> ImageInfo {
        let source = try makeSource(data)
        let format = try format(of: source)
        guard let properties = copyProperties(source),
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { throw .unreadable }
        let swaps = swapsAxes(orientation(of: properties))
        return ImageInfo(
            format: format, pixelWidth: swaps ? height : width, pixelHeight: swaps ? width : height,
            frameCount: CGImageSourceGetCount(source))
    }

    /// Upright pixels in the source color space and bit depth, plus the facts and metadata later stages need.
    static func decode(_ data: Data) throws(CodecError) -> DecodedImage {
        let source = try makeSource(data)
        let format = try format(of: source)
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let stored = CGImageSourceCreateImageAtIndex(source, 0, options) else { throw .unreadable }
        let properties = copyProperties(source) ?? [:]
        let pixels = try upright(stored, orientation: orientation(of: properties))
        let facts = SourceFacts(
            format: format, bitsPerComponent: stored.bitsPerComponent,
            isGrayscale: stored.colorSpace?.model == .monochrome, isCMYK: stored.colorSpace?.model == .cmyk,
            hasAlpha: Redraw.hasAlpha(stored), hasGainMap: hasGainMap(source),
            iccProfile: stored.colorSpace?.copyICCData() as Data?)
        let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        return DecodedImage(pixels: pixels, facts: facts, metadata: SourceMetadata(properties: properties, xmp: xmp),
            sourceData: data)
    }

    // MARK: Source

    private static func makeSource(_ data: Data) throws(CodecError) -> CGImageSource {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
            CGImageSourceGetStatus(source) != .statusInvalidData
        else { throw .unreadable }
        return source
    }

    private static func format(of source: CGImageSource) throws(CodecError) -> ImageFormat {
        guard let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String)
        else { throw .unreadable }
        let candidates: [(UTType?, ImageFormat)] = [
            (.jpeg, .jpeg), (.png, .png), (.heic, .heic), (.webP, .webp), (.tiff, .tiff),
            (UTType("public.avif"), .avif), (UTType("public.jpeg-xl"), .jpegXL)
        ]
        for (candidate, format) in candidates {
            if let candidate, type.conforms(to: candidate) { return format }
        }
        throw .unreadable
    }

    private static func copyProperties(_ source: CGImageSource) -> [CFString: Any]? {
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    static func orientation(of properties: [CFString: Any]) -> Int {
        let value = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (1...8).contains(value) ? value : 1
    }

    private static func swapsAxes(_ orientation: Int) -> Bool { orientation >= 5 }

    private static func hasGainMap(_ source: CGImageSource) -> Bool {
        [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap].contains {
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil
        }
    }

    // MARK: Orientation

    /// Apply orientation while preserving color space, bit depth, and alpha. Orientation 1 returns the original image.
    private static func upright(_ image: CGImage, orientation: Int) throws(CodecError) -> CGImage {
        guard orientation != 1 else { return image }
        let stored = (width: image.width, height: image.height)
        let swaps = swapsAxes(orientation)
        let size = swaps ? (width: stored.height, height: stored.width) : stored
        let transform = transform(orientation: orientation, stored: stored, upright: size)
        guard let result = Redraw.draw(image, width: size.width, height: size.height, transform: transform)
        else { throw .unreadable }
        return result
    }

    /// Map bottom-left CoreGraphics coordinates to upright coordinates using top-left EXIF transforms.
    static func transform(
        orientation: Int, stored: (width: Int, height: Int), upright: (width: Int, height: Int)
    ) -> CGAffineTransform {
        let w = CGFloat(stored.width)
        let h = CGFloat(stored.height)
        // x' = a x + c y + tx, y' = b x + d y + ty, in top-left coordinates.
        let topLeft: CGAffineTransform =
            switch orientation {
            case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
            case 3: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
            case 4: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
            case 5: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
            case 6: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
            case 7: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
            case 8: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
            default: .identity
            }
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(upright.height))
        return flipIn.concatenating(topLeft).concatenating(flipOut)
    }
}

/// Redraws a CGImage into a new bitmap, for orientation (Decode) and bit depth / color conversion (Encode).
enum Redraw {
    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Draw at the requested size. Default to the source color space, or sRGB if unsupported.
    /// Default to the source bit depth, capped at 16. Without `alpha`, composite transparency onto white.
    static func draw(
        _ image: CGImage, width: Int, height: Int, transform: CGAffineTransform = .identity,
        space: CGColorSpace? = nil, bitsPerComponent: Int? = nil, alpha: Bool? = nil
    ) -> CGImage? {
        let source = image.colorSpace
        var space = space ?? source ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bits = bitsPerComponent ?? (image.bitsPerComponent > 8 ? 16 : 8)
        let keepAlpha = alpha ?? hasAlpha(image)
        for attempt in 0..<2 {
            let bitmapInfo: CGBitmapInfo =
                switch space.model {
                case .cmyk: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
                case .monochrome:
                    CGBitmapInfo(rawValue: (keepAlpha ? CGImageAlphaInfo.premultipliedLast : .none).rawValue)
                default:
                    CGBitmapInfo(
                        rawValue: (keepAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)
                }
            if let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0, space: space,
                bitmapInfo: bitmapInfo.rawValue)
            {
                context.interpolationQuality = .none
                if keepAlpha {
                    context.setBlendMode(.copy)
                } else if hasAlpha(image) {
                    context.setFillColor(CGColor(gray: 1, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                }
                context.concatenate(transform)
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return context.makeImage()
            }
            if attempt == 0 { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        }
        return nil
    }
}
