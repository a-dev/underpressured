import Foundation

struct Row: Sendable {
    let file: String
    let encoder: String
    let params: String
    let bytes: Int
    let wallMs: Double
    let ssim: Double?
    let butter: Double?
    let error: String?

    static let header = "file,encoder,params,bytes,wall_ms,ssimulacra2,butteraugli"

    private func esc(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
    var csv: String {
        [esc(file), esc(encoder), esc(params), String(bytes), String(format: "%.2f", wallMs),
         ssim.map { String(format: "%.4f", $0) } ?? "", butter.map { String(format: "%.4f", $0) } ?? ""].joined(separator: ",")
    }
}

enum Mode: Sendable {
    case fixed(quality: Int)
    case matchSSIMULACRA2(target: Double)
}

struct Runner: Sendable {
    let encoder: any Encoder
    let metrics: Metrics
    let mode: Mode
    let work: URL

    func process(_ input: URL) async -> Row {
        do { return try await run(input) }
        catch {
            FileHandle.standardError.write(Data("error: \(input.lastPathComponent): \(error)\n".utf8))
            return Row(file: input.lastPathComponent, encoder: encoder.name, params: "error", bytes: 0,
                       wallMs: 0, ssim: nil, butter: nil, error: "\(error)")
        }
    }

    private func run(_ input: URL) async throws -> Row {
        let dir = work.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ref = dir.appendingPathComponent("reference.png")
        try decodeToPNG(input, ref)
        let src = Prepared(original: input, reference: ref)
        let name = input.lastPathComponent

        switch mode {
        case .fixed(let q):
            let p = EncodeParams(quality: q)
            let o = try await encoder.encode(src, p, work: dir)
            async let s = metrics.ssimulacra2(ref, o.file, work: dir)
            async let b = metrics.butteraugli(ref, o.file, work: dir)
            return Row(file: name, encoder: encoder.name, params: p.description, bytes: o.bytes, wallMs: o.wallMs,
                       ssim: try await s, butter: try await b, error: nil)

        case .matchSSIMULACRA2(let target):
            guard encoder.supportsQuality else { throw BenchError("\(encoder.name) has no quality axis") }
            var lo = 1, hi = 100
            var best: (EncodeParams, EncodeOutput, Double)?
            var iterations = 0
            while lo <= hi && iterations < 8 {
                iterations += 1
                let q = (lo + hi) / 2
                let p = EncodeParams(quality: q)
                let o = try await encoder.encode(src, p, work: dir)
                let s = try await metrics.ssimulacra2(ref, o.file, work: dir)
                if s >= target { best = (p, o, s); hi = q - 1 } else { lo = q + 1 }
            }
            var met = true
            if best == nil {
                // Even the highest probed quality missed the target; report q=100 as unmet.
                met = false
                let p = EncodeParams(quality: 100)
                let o = try await encoder.encode(src, p, work: dir)
                best = (p, o, try await metrics.ssimulacra2(ref, o.file, work: dir))
            }
            let (p, o, s) = best!
            let b = try await metrics.butteraugli(ref, o.file, work: dir)
            return Row(file: name, encoder: encoder.name,
                       params: p.description + (met ? "" : " target-unmet"), bytes: o.bytes, wallMs: o.wallMs,
                       ssim: s, butter: b, error: nil)
        }
    }
}
