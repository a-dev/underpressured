import UnderpressuredApplication
import Accelerate
import CoreGraphics
import Foundation
import UnderpressuredCore

/// 8-bit interleaved pixels for native encoders. RGB and gray preserve their color space and ICC profile.
/// Convert other color spaces to sRGB.
struct PixelBuffer: Sendable {
    enum Layout: Sendable {
        case gray8
        case rgb8
        /// Non-premultiplied RGBA, as quantizr expects.
        case rgba8

        var channels: Int {
            switch self {
            case .gray8: 1
            case .rgb8: 3
            case .rgba8: 4
            }
        }
    }

    var bytes: [UInt8]
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var layout: Layout
    /// The profile of the space the pixels are in: the source's when kept, sRGB's after a conversion.
    var iccProfile: Data?

    /// - Parameters:
    ///   - sourceProfile: the source's embedded profile, carried unchanged when the space is kept.
    ///   - forceSRGB: render to sRGB even when the source is gray (palette PNG is always RGB).
    static func render(
        _ image: CGImage, layout: Layout, sourceProfile: Data?, forceSRGB: Bool = false
    ) throws(CodecError) -> PixelBuffer {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let own = image.colorSpace
        let model = own?.model
        let keepsOwn: Bool
        switch layout {
        case .gray8: keepsOwn = model == .monochrome
        case .rgb8, .rgba8: keepsOwn = model == .rgb && !forceSRGB
        }
        let space: CGColorSpace
        if keepsOwn, let own {
            space = own
        } else if layout == .gray8 {
            space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        } else {
            space = srgb
        }
        let profile = keepsOwn ? sourceProfile : space.copyICCData() as Data?

        let width = image.width
        let height = image.height
        let contextChannels = layout == .gray8 ? 1 : 4
        let contextRow = width * contextChannels
        var context = [UInt8](repeating: 0, count: contextRow * height)
        let alphaInfo: CGImageAlphaInfo = switch layout {
        case .gray8: .none
        case .rgb8: .noneSkipLast
        case .rgba8: .premultipliedLast
        }
        let drawn = context.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: contextRow, space: space, bitmapInfo: alphaInfo.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw .encodeFailed("Can't render \(width)x\(height) pixels for the encoder") }

        switch layout {
        case .gray8:
            return PixelBuffer(
                bytes: context, width: width, height: height, bytesPerRow: contextRow, layout: layout,
                iccProfile: profile)
        case .rgba8:
            context.withUnsafeMutableBytes { buf in
                var vbuf = vImage_Buffer(
                    data: buf.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: contextRow)
                _ = vImageUnpremultiplyData_RGBA8888(&vbuf, &vbuf, vImage_Flags(kvImageNoFlags))
            }
            return PixelBuffer(
                bytes: context, width: width, height: height, bytesPerRow: contextRow, layout: layout,
                iccProfile: profile)
        case .rgb8:
            let row = width * 3
            var packed = [UInt8](repeating: 0, count: row * height)
            context.withUnsafeMutableBytes { src in
                packed.withUnsafeMutableBytes { dst in
                    var s = vImage_Buffer(
                        data: src.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                        rowBytes: contextRow)
                    var d = vImage_Buffer(
                        data: dst.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                        rowBytes: row)
                    _ = vImageConvert_RGBA8888toRGB888(&s, &d, vImage_Flags(kvImageNoFlags))
                }
            }
            return PixelBuffer(
                bytes: packed, width: width, height: height, bytesPerRow: row, layout: layout, iccProfile: profile)
        }
    }
}
