import Accelerate
import Foundation

// Copied verbatim from bench/resize/Sources/resize/Methods.swift (method C).
let singleThread = vImage_Flags(kvImageHighQualityResampling | kvImageDoNotTile)

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

