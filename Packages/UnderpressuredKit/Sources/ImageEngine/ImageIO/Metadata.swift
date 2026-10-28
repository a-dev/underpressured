import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import UnderpressuredCore

/// Controls output metadata.
enum Metadata {
    /// Property groups Keep metadata carries over. Pixel-layout keys (size, depth, profile, JFIF) are not copied.
    private static var keptGroups: [CFString] {
        [
            kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
            kCGImagePropertyTIFFDictionary
        ]
    }
    /// Stale after resizing, so never copied.
    private static var layoutKeys: [CFString] {
        [kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension]
    }
    private static var tiffLayoutKeys: [CFString] { [kCGImagePropertyTIFFOrientation] }

    /// Write the image and color profile. With Keep metadata, preserve EXIF, XMP, IPTC, and GPS with orientation 1.
    /// Never write gain maps. Return the resulting notes.
    static func addImage(
        _ image: DecodedImage, to destination: CGImageDestination, encodeOptions: [CFString: Any],
        keepMetadata: Bool
    ) -> [Note] {
        var options = encodeOptions
        if keepMetadata { merge(image.metadata.properties, into: &options) }
        if keepMetadata, let xmp = image.metadata.xmp, let tree = upright(xmp) {
            CGImageDestinationAddImageAndMetadata(destination, image.pixels, tree, options as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image.pixels, options as CFDictionary)
        }
        return image.facts.hasGainMap ? [.hdrRemoved] : []
    }

    static func merge(_ source: [CFString: Any], into options: inout [CFString: Any]) {
        for group in keptGroups {
            guard var values = source[group] as? [CFString: Any] else { continue }
            let drop = group == kCGImagePropertyTIFFDictionary ? tiffLayoutKeys : layoutKeys
            for key in drop { values.removeValue(forKey: key) }
            if !values.isEmpty { options[group] = values }
        }
        if let tiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any], tiff[kCGImagePropertyTIFFOrientation] != nil
        {
            var values = options[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            values[kCGImagePropertyTIFFOrientation] = 1
            options[kCGImagePropertyTIFFDictionary] = values
        }
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = source[key] { options[key] = value }
        }
        options[kCGImagePropertyOrientation] = 1
    }

    /// A copy of the XMP tree with `tiff:Orientation` reset to 1 and the pixel dimensions removed.
    static func upright(_ xmp: CGImageMetadata) -> CGImageMetadata? {
        guard let tree = CGImageMetadataCreateMutableCopy(xmp) else { return nil }
        for path in ["exif:PixelXDimension", "exif:PixelYDimension"] {
            CGImageMetadataRemoveTagWithPath(tree, nil, path as CFString)
        }
        if CGImageMetadataCopyTagWithPath(tree, nil, "tiff:Orientation" as CFString) != nil {
            CGImageMetadataSetValueWithPath(tree, nil, "tiff:Orientation" as CFString, "1" as CFString)
        }
        return tree
    }
}
