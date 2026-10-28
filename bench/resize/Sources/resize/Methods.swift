import Accelerate
import CoreGraphics
import Foundation
import ImageIO

enum Method: String, CaseIterable {
    case A, B, C, D

    var summary: String {
        switch self {
        case .A: return "ImageIO thumbnail"
        case .B: return "vImage Lanczos, gamma 8-bit"
        case .C: return "vImage Lanczos, linear float"
        case .D: return "CGContext .high"
        }
    }
}

let singleThread = vImage_Flags(kvImageHighQualityResampling | kvImageDoNotTile)

/// A: ImageIO thumbnail straight from the file (may use JPEG DCT-domain scaling),
/// then a 1:1 draw into an sRGB RGBX buffer (forces decode, converts profile).
func resizeA(url: URL, longEdge: Int) throws -> Pixels {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw BenchError("open failed: \(url.path)")
    }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: false,
        kCGImageSourceThumbnailMaxPixelSize: longEdge,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
        throw BenchError("thumbnail failed: \(url.path)")
    }
    return redraw(thumb)
}

/// B: vImage Lanczos directly on the gamma-encoded 8-bit sRGB samples.
func resizeB(_ src: Pixels, width: Int, height: Int) throws -> Pixels {
    let dst = Pixels(width: width, height: height)
    var s = vImage_Buffer(
        data: src.data, height: vImagePixelCount(src.height), width: vImagePixelCount(src.width),
        rowBytes: src.rowBytes)
    var d = vImage_Buffer(
        data: dst.data, height: vImagePixelCount(height), width: vImagePixelCount(width),
        rowBytes: dst.rowBytes)
    let err = vImageScale_ARGB8888(&s, &d, nil, singleThread)
    guard err == kvImageNoError else { throw BenchError("vImageScale_ARGB8888: \(err)") }
    return dst
}

/// C: sRGB 8-bit -> linear float (vImage gamma), vImageScale_ARGBFFFF Lanczos,
/// linear float -> sRGB 8-bit (vImage gamma). The skip channel rides along as a 4th channel.
func resizeC(_ src: Pixels, width: Int, height: Int) throws -> Pixels {
    let dst = Pixels(width: width, height: height)
    let sCount = src.width * src.height * 4
    let dCount = width * height * 4
    let fSrc = UnsafeMutablePointer<Float>.allocate(capacity: sCount)
    let fDst = UnsafeMutablePointer<Float>.allocate(capacity: dCount)
    defer {
        fSrc.deallocate()
        fDst.deallocate()
    }
    let toLinear = vImageCreateGammaFunction(0, Int32(kvImageGamma_sRGB_forward_half_precision), 0)
    let toSRGB = vImageCreateGammaFunction(0, Int32(kvImageGamma_sRGB_reverse_half_precision), 0)
    defer {
        vImageDestroyGammaFunction(toLinear)
        vImageDestroyGammaFunction(toSRGB)
    }
    let flags = vImage_Flags(kvImageDoNotTile)
    var s8 = vImage_Buffer(
        data: src.data, height: vImagePixelCount(src.height), width: vImagePixelCount(src.width * 4),
        rowBytes: src.rowBytes)
    var sF = vImage_Buffer(
        data: fSrc, height: vImagePixelCount(src.height), width: vImagePixelCount(src.width * 4),
        rowBytes: src.width * 16)
    var e = vImageGamma_Planar8toPlanarF(&s8, &sF, toLinear, flags)
    guard e == kvImageNoError else { throw BenchError("vImageGamma_Planar8toPlanarF: \(e)") }

    var sA = vImage_Buffer(
        data: fSrc, height: vImagePixelCount(src.height), width: vImagePixelCount(src.width),
        rowBytes: src.width * 16)
    var dA = vImage_Buffer(
        data: fDst, height: vImagePixelCount(height), width: vImagePixelCount(width),
        rowBytes: width * 16)
    e = vImageScale_ARGBFFFF(&sA, &dA, nil, singleThread)
    guard e == kvImageNoError else { throw BenchError("vImageScale_ARGBFFFF: \(e)") }

    var dF = vImage_Buffer(
        data: fDst, height: vImagePixelCount(height), width: vImagePixelCount(width * 4),
        rowBytes: width * 16)
    var d8 = vImage_Buffer(
        data: dst.data, height: vImagePixelCount(height), width: vImagePixelCount(width * 4),
        rowBytes: dst.rowBytes)
    e = vImageGamma_PlanarFtoPlanar8(&dF, &d8, toSRGB, flags)
    guard e == kvImageNoError else { throw BenchError("vImageGamma_PlanarFtoPlanar8: \(e)") }
    return dst
}

/// D: CGContext draw with high interpolation quality, gamma-encoded samples.
func resizeD(_ src: Pixels, width: Int, height: Int) throws -> Pixels {
    let dst = Pixels(width: width, height: height)
    guard
        let provider = CGDataProvider(
            dataInfo: nil, data: src.data, size: src.rowBytes * src.height,
            releaseData: { _, _, _ in }),
        let img = CGImage(
            width: src.width, height: src.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: src.rowBytes, space: sRGBSpace(), bitmapInfo: rgbxInfo,
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { throw BenchError("CGImage create failed") }
    let ctx = makeContext(dst)
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
    return dst
}

/// Sanity check of the vImage gamma round trip over all 256 codes (method C's colour path).
func gammaRoundTripMaxError() throws -> Int {
    let p = Pixels(width: 64, height: 4)
    let bytes = p.data.assumingMemoryBound(to: UInt8.self)
    for i in 0..<(64 * 4 * 4) { bytes[i] = UInt8(i % 256) }
    let q = try resizeC(p, width: 64, height: 4)  // same size: scale is identity
    let qb = q.data.assumingMemoryBound(to: UInt8.self)
    var worst = 0
    for i in 0..<(64 * 4 * 4) { worst = max(worst, abs(Int(qb[i]) - Int(bytes[i]))) }
    return worst
}
