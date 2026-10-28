import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Tightly packed 8-bit RGBX buffer (R,G,B,skip), sRGB. rowBytes == width * 4.
final class Pixels: @unchecked Sendable {
    let width: Int
    let height: Int
    let data: UnsafeMutableRawPointer
    var rowBytes: Int { width * 4 }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        data = calloc(width * height * 4, 1)!
    }

    deinit { free(data) }
}

struct SendPtr<T>: @unchecked Sendable {
    let p: UnsafeMutablePointer<T>
}

func sRGBSpace() -> CGColorSpace {
    CGColorSpace(name: CGColorSpace.sRGB)!
}

let rgbxInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)

func makeContext(_ p: Pixels) -> CGContext {
    CGContext(
        data: p.data, width: p.width, height: p.height, bitsPerComponent: 8,
        bytesPerRow: p.rowBytes, space: sRGBSpace(), bitmapInfo: rgbxInfo.rawValue)!
}

/// Decode with ImageIO and convert to 8-bit sRGB RGBX (ColorSync does the
/// profile conversion inside `draw`). Pixels are unrotated (EXIF ignored).
func decodeSRGB8(_ url: URL) throws -> Pixels {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let img = CGImageSourceCreateImageAtIndex(
            src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { throw BenchError("decode failed: \(url.path)") }
    return redraw(img)
}

/// 1:1 draw of any CGImage into a fresh sRGB RGBX buffer (colour-converts, no resampling).
func redraw(_ img: CGImage) -> Pixels {
    let p = Pixels(width: img.width, height: img.height)
    let ctx = makeContext(p)
    ctx.interpolationQuality = .none
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return p
}

struct SourceInfo {
    let width: Int
    let height: Int
    let profile: String
    let orientation: Int
}

func sourceInfo(_ url: URL) throws -> SourceInfo {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
        let w = props[kCGImagePropertyPixelWidth] as? Int,
        let h = props[kCGImagePropertyPixelHeight] as? Int
    else { throw BenchError("cannot read properties: \(url.path)") }
    return SourceInfo(
        width: w, height: h,
        profile: (props[kCGImagePropertyProfileName] as? String) ?? "(none)",
        orientation: (props[kCGImagePropertyOrientation] as? Int) ?? 1)
}

func writePNG(_ p: Pixels, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let img = makeContext(p).makeImage(),
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw BenchError("png write setup failed: \(url.path)") }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { throw BenchError("png finalize failed: \(url.path)") }
}

struct CorpusItem {
    let id: String
    let category: String
    let url: URL
}

func loadCorpus(benchDir: URL) throws -> [CorpusItem] {
    var items: [CorpusItem] = []
    for (dir, ext) in [("photo", "jpg"), ("screenshot", "png")] {
        let d = benchDir.appendingPathComponent("corpus/\(dir)")
        let files = try FileManager.default.contentsOfDirectory(atPath: d.path)
            .filter { $0.hasSuffix(".\(ext)") }.sorted()
        for f in files {
            items.append(
                CorpusItem(
                    id: String(f.dropLast(ext.count + 1)), category: dir,
                    url: d.appendingPathComponent(f)))
        }
    }
    return items
}

/// Output size for a long-edge target, or nil when the source is not larger
/// than the target (no downscale needed, image skipped).
func targetSize(width: Int, height: Int, longEdge: Int) -> (Int, Int)? {
    let long = max(width, height)
    guard long > longEdge else { return nil }
    let f = Double(longEdge) / Double(long)
    if width >= height { return (longEdge, max(1, Int((Double(height) * f).rounded()))) }
    return (max(1, Int((Double(width) * f).rounded())), longEdge)
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return .nan }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func wallNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func cpuNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) }

/// Runs `body` and returns (wall ms, process-CPU ms, result).
func timed<T>(_ body: () throws -> T) rethrows -> (Double, Double, T) {
    let w0 = wallNs()
    let c0 = cpuNs()
    let r = try body()
    let c1 = cpuNs()
    let w1 = wallNs()
    return (Double(w1 - w0) / 1e6, Double(c1 - c0) / 1e6, r)
}
