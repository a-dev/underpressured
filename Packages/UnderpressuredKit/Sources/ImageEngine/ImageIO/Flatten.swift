import UnderpressuredApplication
import CoreGraphics
import UnderpressuredCore

/// Composites transparency onto white for JPEG output.
enum Flatten {
    static func ontoWhite(_ image: DecodedImage) throws(CodecError) -> DecodedImage {
        let source = image.pixels
        guard hasAlpha(source) else { return image }

        let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let isGray: Bool
        switch colorSpace.model {
        case .monochrome: isGray = true
        case .rgb: isGray = false
        default: throw CodecError.encodeFailed("flatten: unsupported color model \(colorSpace.model.rawValue)")
        }
        let bits = source.bitsPerComponent
        guard bits == 8 || bits == 16 else {
            throw CodecError.encodeFailed("flatten: unsupported bit depth \(bits)")
        }

        let width = source.width
        let height = source.height
        let alpha: CGImageAlphaInfo = isGray ? .none : .noneSkipLast
        let bitmapInfo = CGBitmapInfo(rawValue: alpha.rawValue)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue)
        else {
            throw CodecError.encodeFailed("flatten: cannot create a \(width)x\(height) context")
        }

        // White in the image's own color space: one component per channel, plus alpha.
        let whiteComponents = [CGFloat](repeating: 1, count: colorSpace.numberOfComponents + 1)
        guard let white = CGColor(colorSpace: colorSpace, components: whiteComponents) else {
            throw CodecError.encodeFailed("flatten: cannot make white in the source color space")
        }
        context.setFillColor(white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let flat = context.makeImage() else {
            throw CodecError.encodeFailed("flatten: cannot make the flattened image")
        }

        var result = image
        result.pixels = flat
        result.facts.hasAlpha = false
        result.pixelsTransformed = true
        return result
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
