import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import UnderpressuredCore
import UniformTypeIdentifiers

/// Encodes 8-bit gray or RGB pixels with jpegli, including the ICC profile.
/// ImageIO adds optional EXIF, XMP, IPTC, and GPS without changing progressive scans or DCT coefficients.
enum JPEGEncode {
    /// Butteraugli distance for the lossless-on re-encode (§7.4: "visually lossless").
    static let visuallyLosslessDistance: Float = 1.0

    static func lossy(_ image: DecodedImage, _ plan: EncodePlan) throws(CodecError) -> EncodedImage {
        try encode(image, plan, notes: []) { buffer, components, bytes throws(JpegliError) in
            try Jpegli.encode(
                pixels: bytes, width: buffer.width, height: buffer.height, bytesPerRow: buffer.bytesPerRow,
                components: components, quality: plan.quality.rawValue, progressive: true, iccProfile: buffer.iccProfile)
        }
    }

    static func visuallyLossless(
        _ image: DecodedImage, _ plan: EncodePlan,
        encoder: Jpegli.DistanceEncoder = Jpegli.encode
    ) throws(CodecError) -> EncodedImage {
        try encode(image, plan, notes: [.reencodedVisuallyLossless]) { buffer, components, bytes throws(JpegliError) in
            try encoder(
                bytes, buffer.width, buffer.height, buffer.bytesPerRow, components,
                visuallyLosslessDistance, true, buffer.iccProfile)
        }
    }

    private static func encode(
        _ image: DecodedImage, _ plan: EncodePlan, notes extra: [Note],
        run: (PixelBuffer, Jpegli.Components, UnsafeRawBufferPointer) throws(JpegliError) -> Data
    ) throws(CodecError) -> EncodedImage {
        let isGray = image.pixels.colorSpace?.model == .monochrome
        let buffer = try PixelBuffer.render(
            image.pixels, layout: isGray ? .gray8 : .rgb8, sourceProfile: image.facts.iccProfile)
        let components: Jpegli.Components = isGray ? .gray : .rgb
        let encoded = buffer.bytes.withUnsafeBytes { bytes in
            Result<Data, JpegliError> { () throws(JpegliError) in try run(buffer, components, bytes) }
        }
        var data: Data
        switch encoded {
        case .success(let value): data = value
        case .failure(let error): throw .encodeFailed("jpegli: \(error)")
        }
        if plan.keepMetadata { data = try addMetadata(image, to: data) }
        let notes: [Note] = image.facts.hasGainMap ? [.hdrRemoved] : []
        return EncodedImage(
            data: data, format: .jpeg, pixelWidth: buffer.width, pixelHeight: buffer.height,
            notes: image.notes + notes + extra)
    }

    /// Adds the kept metadata without touching the compressed image data.
    private static func addMetadata(_ image: DecodedImage, to jpeg: Data) throws(CodecError) -> Data {
        var options: [CFString: Any] = [:]
        Metadata.merge(image.metadata.properties, into: &options)
        if let xmp = image.metadata.xmp, let tree = Metadata.upright(xmp) {
            options[kCGImageDestinationMetadata] = tree
            options[kCGImageDestinationMergeMetadata] = true
        }
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else {
            throw .encodeFailed("jpegli output isn't readable")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw .encodeFailed("Can't create the JPEG metadata writer") }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            throw .encodeFailed("Can't add metadata: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        return output as Data
    }
}
