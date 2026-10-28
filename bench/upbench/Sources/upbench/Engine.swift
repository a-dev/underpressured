import UnderpressuredApplication
import Foundation
import ImageEngine
import UnderpressuredCore

/// `upbench engine`: runs files through the real `NativeCodec` (decode, transform, encode, §7.3
/// steps 2-8) with the starter Presets plus a Lossless variant, and writes one CSV row per
/// (file, preset). Savings follow the app: a skipped Item counts as 0%.
///
/// usage: upbench engine --input <dir or files...> --out <csv> [--presets Balanced,Web,Small,Lossless]
enum EngineMode {
    static let usage = "usage: upbench engine --input <dir or files...> --out <csv> [--presets a,b,...]"

    static func presets() -> [Preset] {
        Preset.starters + [
            Preset(name: "Lossless", quality: 80, lossless: true, resizeRule: .none, keepMetadata: false),
            Preset(name: "LosslessWeb", quality: 80, lossless: true, resizeRule: .maxLongEdge(2048), keepMetadata: false)
        ]
    }

    static func run(_ argv: [String]) async {
        var inputs: [String] = []
        var outPath: String?
        var wanted: Set<String>?
        var args = argv[...]
        while let a = args.popFirst() {
            switch a {
            case "--input":
                while let n = args.first, !n.hasPrefix("--") { inputs.append(n); args.removeFirst() }
            case "--out": outPath = args.popFirst()
            case "--presets": wanted = Set((args.popFirst() ?? "").split(separator: ",").map(String.init))
            default: fail("unknown argument \(a)")
            }
        }
        guard let outPath, !inputs.isEmpty else { fail(usage) }

        let exts: Set<String> = ["jpg", "jpeg", "png"]
        var files: [URL] = []
        for p in inputs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { fail("no such input: \(p)") }
            if isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []
                for n in items.sorted() where exts.contains((n as NSString).pathExtension.lowercased()) {
                    files.append(URL(fileURLWithPath: p).appendingPathComponent(n))
                }
            } else {
                files.append(URL(fileURLWithPath: p))
            }
        }
        let list = presets().filter { wanted?.contains($0.name) ?? true }
        let codec = NativeCodec()
        var rows = ["file,category,preset,format,src_bytes,out_bytes,out_w,out_h,ms,savings_pct,skipped,notes"]
        for file in files {
            let category = file.deletingLastPathComponent().lastPathComponent
            for preset in list {
                let row = await one(file, category, preset, codec)
                FileHandle.standardError.write(Data((row + "\n").utf8))
                rows.append(row)
            }
        }
        let url = URL(fileURLWithPath: outPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { fail("cannot write \(outPath): \(error)") }
    }

    static func one(_ file: URL, _ category: String, _ preset: Preset, _ codec: NativeCodec) async -> String {
        let name = file.lastPathComponent
        let fail = { (why: String) in "\(name),\(category),\(preset.name),,,,,,,,error,\(why.replacingOccurrences(of: ",", with: ";"))" }
        guard let data = try? Data(contentsOf: file) else { return fail("read") }
        let start = ContinuousClock.now
        do {
            let info = try await codec.inspect(data)
            let format: WritableFormat
            switch info.format {
            case .jpeg: format = .jpeg
            case .png: format = .png
            default: return fail("unsupported \(info.format)")
            }
            let decoded = try await codec.decode(data)
            let transformed = try await codec.transform(
                decoded, TransformPlan(resizeRule: preset.resizeRule, flattenOntoWhite: format == .jpeg))
            let encoded = try await codec.encode(
                transformed,
                EncodePlan(format: format, quality: preset.quality, lossless: preset.lossless, keepMetadata: preset.keepMetadata))
            let decision = NotSmallerRule.decide(
                sourceFormat: info.format, sourcePixelWidth: info.pixelWidth, sourcePixelHeight: info.pixelHeight,
                sourceBytes: Int64(data.count), outputFormat: encoded.format, outputPixelWidth: encoded.pixelWidth,
                outputPixelHeight: encoded.pixelHeight, outputBytes: Int64(encoded.data.count))
            var skipped = false
            if case .skip = decision { skipped = true }
            let c = start.duration(to: .now).components
            let ms = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
            let pct = skipped ? 0 : 100 * (1 - Double(encoded.data.count) / Double(data.count))
            let notes = encoded.notes.map { String(describing: $0) }.joined(separator: "|")
            return "\(name),\(category),\(preset.name),\(format),\(data.count),\(encoded.data.count),\(encoded.pixelWidth),\(encoded.pixelHeight),"
                + String(format: "%.0f,%.2f", ms, pct) + ",\(skipped),\(notes)"
        } catch {
            return fail("\(error)")
        }
    }
}
