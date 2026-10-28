import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Parameters for one encode. Later tasks add fields (resize, palette size, ...).
struct EncodeParams: Sendable {
    var quality: Int
    var description: String { "q=\(quality)" }
}

struct EncodeOutput: Sendable {
    let file: URL
    let bytes: Int
    let wallMs: Double
}

/// A file prepared for benchmarking: `reference` is the source decoded to PNG.
struct Prepared: Sendable {
    let original: URL
    let reference: URL
}

/// Add new encoders by conforming and registering in `EncoderKind`.
protocol Encoder: Sendable {
    var name: String { get }
    /// True if `quality` is a meaningful search axis (for --match-ssimulacra2).
    var supportsQuality: Bool { get }
    func encode(_ src: Prepared, _ params: EncodeParams, work: URL) async throws -> EncodeOutput
}

enum EncoderKind: String, CaseIterable, Sendable {
    case imageioJpeg = "imageio-jpeg"
    case jpegli

    func make(tools: Tools) -> any Encoder {
        switch self {
        case .imageioJpeg: ImageIOJPEG()
        case .jpegli: Jpegli(tools: tools)
        }
    }
}

struct ImageIOJPEG: Encoder {
    let name = "imageio-jpeg"
    let supportsQuality = true

    func encode(_ src: Prepared, _ params: EncodeParams, work: URL) async throws -> EncodeOutput {
        // Decode is outside the timed region; only the encode + finalize is timed.
        guard let s = CGImageSourceCreateWithURL(src.reference as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(s, 0, nil)
        else { throw ImageError.decode(src.reference.lastPathComponent) }
        let out = work.appendingPathComponent("\(UUID().uuidString).jpg")
        let clock = ContinuousClock()
        let t0 = clock.now
        let data = NSMutableData()
        guard let d = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ImageError.encode("jpeg dest") }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Double(params.quality) / 100]
        CGImageDestinationAddImage(d, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw ImageError.encode("jpeg finalize") }
        let el = clock.now - t0
        try (data as Data).write(to: out)
        let ms = Double(el.components.seconds) * 1000 + Double(el.components.attoseconds) / 1e15
        return EncodeOutput(file: out, bytes: data.length, wallMs: ms)
    }
}

struct Jpegli: Encoder {
    let name = "jpegli"
    let supportsQuality = true
    let tools: Tools

    func encode(_ src: Prepared, _ params: EncodeParams, work: URL) async throws -> EncodeOutput {
        let out = work.appendingPathComponent("\(UUID().uuidString).jpg")
        let r = try await runProcess(tools.url("cjpegli"),
                                     [src.reference.path, out.path, "-q", String(params.quality)],
                                     scratch: work)
        guard r.status == 0 else { throw BenchError("cjpegli exit \(r.status): \(r.stderr.prefix(200))") }
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        return EncodeOutput(file: out, bytes: size, wallMs: r.wallMs)
    }
}
