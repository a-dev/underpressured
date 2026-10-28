import CJpegli
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// q7 prep <corpus-photo-dir> <inputs-dir>        build 100 ~12 MP inputs
// q7 run  <inputs-dir> <outputs-dir> <workers> <label>   time the pipeline, print one summary line

let args = CommandLine.arguments
func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

func prep(corpus: String, outDir: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let files = try fm.contentsOfDirectory(atPath: corpus).filter { $0.hasSuffix(".jpg") }.sorted()
    var n = 0
    for f in files {
        let url = URL(fileURLWithPath: corpus).appendingPathComponent(f)
        let info = try sourceInfo(url)
        let scale = min(1.0, (12_000_000.0 / Double(info.width * info.height)).squareRoot())
        let maxPx = Int((Double(max(info.width, info.height)) * scale).rounded())
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let img = CGImageSourceCreateThumbnailAtIndex(
                src, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPx,
                    kCGImageSourceCreateThumbnailWithTransform: false,
                ] as CFDictionary)
        else { throw BenchError("thumbnail failed \(f)") }
        let base = String(f.dropLast(4))
        let first = URL(fileURLWithPath: outDir).appendingPathComponent("\(base)-v1.jpg")
        guard let dest = CGImageDestinationCreateWithURL(
            first as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw BenchError("dest failed") }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw BenchError("finalize failed") }
        print("\(f): \(info.width)x\(info.height) -> \(img.width)x\(img.height)")
        for v in 2...5 {
            let dst = URL(fileURLWithPath: outDir).appendingPathComponent("\(base)-v\(v).jpg")
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: first, to: dst)
        }
        n += 5
    }
    print("wrote \(n) inputs to \(outDir)")
}

final class Stats: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    var dec: [Double] = [], rsz: [Double] = [], enc: [Double] = [], wr: [Double] = []
    var outBytes = 0
    var failures = 0
    func take(_ count: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard next < count else { return nil }
        next += 1
        return next - 1
    }
    func record(_ d: Double, _ r: Double, _ e: Double, _ w: Double, _ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        dec.append(d); rsz.append(r); enc.append(e); wr.append(w); outBytes += bytes
    }
    func fail() { lock.lock(); failures += 1; lock.unlock() }
}

func process(_ inURL: URL, _ outURL: URL, _ st: Stats) {
    do {
        let (tD, _, px) = try timed { try decodeSRGB8(inURL) }
        guard let (w, h) = targetSize(width: px.width, height: px.height, longEdge: 2048)
        else { throw BenchError("not larger than 2048: \(inURL.lastPathComponent)") }
        let (tR, _, small) = try timed { try resizeC(px, width: w, height: h) }
        let (tE, _, enc) = try timed { () throws -> (UnsafeMutablePointer<UInt8>, Int) in
            var out: UnsafeMutablePointer<UInt8>? = nil
            var size = 0
            let rc = cjpegli_encode_rgbx(
                small.data.assumingMemoryBound(to: UInt8.self), Int32(w), Int32(h), small.rowBytes, 80,
                &out, &size)
            guard rc == 0, let o = out else { throw BenchError("jpegli encode failed") }
            return (o, size)
        }
        let (tW, _, _) = try timed {
            let data = Data(bytesNoCopy: enc.0, count: enc.1, deallocator: .free)
            try data.write(to: outURL)
        }
        st.record(tD, tR, tE, tW, enc.1)
    } catch {
        FileHandle.standardError.write(Data("ERROR \(inURL.lastPathComponent): \(error)\n".utf8))
        st.fail()
    }
}

func run(inputs: String, outputs: String, workers: Int, label: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: outputs, withIntermediateDirectories: true)
    let files = try fm.contentsOfDirectory(atPath: inputs).filter { $0.hasSuffix(".jpg") }.sorted()
    let st = Stats()
    let inDir = URL(fileURLWithPath: inputs), outDir = URL(fileURLWithPath: outputs)
    let t0 = wallNs()
    DispatchQueue.concurrentPerform(iterations: workers) { _ in
        while let i = st.take(files.count) {
            process(inDir.appendingPathComponent(files[i]), outDir.appendingPathComponent(files[i]), st)
        }
    }
    let wall = Double(wallNs() - t0) / 1e9
    print(String(
        format: "%@ files=%d fail=%d workers=%d wall_s=%.3f dec_ms=%.1f rsz_ms=%.1f enc_ms=%.1f write_ms=%.1f out_mb=%.1f",
        label, files.count, st.failures, workers, wall, median(st.dec), median(st.rsz), median(st.enc),
        median(st.wr), Double(st.outBytes) / 1e6))
}

do {
    switch args.dropFirst().first {
    case "prep" where args.count == 4: try prep(corpus: args[2], outDir: args[3])
    case "run" where args.count == 6:
        try run(inputs: args[2], outputs: args[3], workers: Int(args[4])!, label: args[5])
    default: fail("usage: q7 prep <corpus-dir> <inputs-dir> | q7 run <inputs> <outputs> <workers> <label>")
    }
} catch { fail("\(error)") }
