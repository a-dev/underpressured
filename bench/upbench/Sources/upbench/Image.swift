import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageError: Error, CustomStringConvertible {
    case decode(String), encode(String)
    var description: String {
        switch self { case .decode(let s): "decode failed: \(s)"; case .encode(let s): "encode failed: \(s)" }
    }
}

/// Decodes `src` with ImageIO and writes the raw pixels to `dst` as PNG.
/// Orientation: EXIF orientation is deliberately NOT applied. CGImageSourceCreateImageAtIndex
/// returns stored (unrotated) pixels, and every encoder + metric sees those same pixels,
/// so scores are consistent. Output files therefore carry no orientation tag.
func decodeToPNG(_ src: URL, _ dst: URL) throws {
    guard let s = CGImageSourceCreateWithURL(src as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(s, 0, nil)
    else { throw ImageError.decode(src.lastPathComponent) }
    guard let d = CGImageDestinationCreateWithURL(dst as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw ImageError.encode("png dest") }
    CGImageDestinationAddImage(d, img, nil)
    guard CGImageDestinationFinalize(d) else { throw ImageError.encode("png finalize") }
}
