import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UnderpressuredCore

/// Fallback ImageIO encoders.
enum Encode {
    static func encode(_ image: DecodedImage, _ plan: EncodePlan) throws(CodecError) -> EncodedImage {
        var prepared = image
        prepared.pixels = try prepare(image.pixels, plan)

        let type: UTType = plan.format == .jpeg ? .jpeg : .png
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        else { throw .encodeFailed("Can't create the \(plan.format.imageFormat.displayName) encoder") }

        var options: [CFString: Any] = [:]
        if plan.format == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = Double(plan.quality.rawValue) / 100
            options[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true]
        }
        let notes = Metadata.addImage(
            prepared, to: destination, encodeOptions: options, keepMetadata: plan.keepMetadata)
        guard CGImageDestinationFinalize(destination) else {
            throw .encodeFailed("\(plan.format.imageFormat.displayName) encoding failed")
        }
        return EncodedImage(
            data: output as Data, format: plan.format, pixelWidth: prepared.pixels.width,
            pixelHeight: prepared.pixels.height, notes: image.notes + notes)
    }

    /// Convert CMYK to sRGB. Preserve grayscale. Keep 16-bit depth only for lossless PNG.
    /// JPEG output has no alpha.
    static func prepare(_ pixels: CGImage, _ plan: EncodePlan) throws(CodecError) -> CGImage {
        let isCMYK = pixels.colorSpace?.model == .cmyk
        let keep16 = plan.format == .png && plan.lossless
        let targetBits = keep16 && pixels.bitsPerComponent > 8 ? 16 : 8
        let isFloat = pixels.bitmapInfo.contains(.floatComponents)
        let dropAlpha = plan.format == .jpeg && Redraw.hasAlpha(pixels)
        let needsRedraw = isCMYK || dropAlpha || isFloat || pixels.bitsPerComponent != targetBits
        guard needsRedraw else { return pixels }
        let space = isCMYK ? CGColorSpace(name: CGColorSpace.sRGB) : nil
        guard
            let result = Redraw.draw(
                pixels, width: pixels.width, height: pixels.height, space: space, bitsPerComponent: targetBits,
                alpha: plan.format == .png && Redraw.hasAlpha(pixels))
        else { throw .encodeFailed("Can't convert the pixels for \(plan.format.imageFormat.displayName)") }
        return result
    }
}
