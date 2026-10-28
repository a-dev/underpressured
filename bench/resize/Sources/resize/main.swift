import Dispatch
import Foundation

let sizes = [2048, 1280]

struct Config: Sendable {
    var benchDir = URL(fileURLWithPath: "bench")
    var ids: Set<String> = []
    var reps = 3
    var taps = 4
    var jobs = 2
    var methods: [Method] = []
    var out: URL { benchDir.appendingPathComponent("out/q4") }
}

func usage() -> Never {
    print(
        """
        usage: resize <command> [options]
          info                       print corpus dims, ICC profile, orientation
          selftest                   check the vImage gamma round trip used by method C
          ref                        write reference downscales to out/q4/ref/<size>/<id>.png
          time <A|B|C|D>             timed sweep of one method; writes out/q4/time-<M>.csv + output PNGs
                                     (wrap in the bench timing lock; see bench/q4/RESULTS.md)
          score                      SSIMULACRA2 + Butteraugli of every output vs reference -> scores.csv
          report                     markdown tables from the CSVs on stdout
        options: --bench-dir DIR (default ./bench)  --ids a,b  --reps N (3)  --taps N (4)  --jobs N (2)
        """)
    exit(2)
}

func parseArgs() -> (String, Config) {
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { usage() }
    let command = args.removeFirst()
    var cfg = Config()
    var i = 0
    func next() -> String {
        i += 1
        guard i < args.count else { usage() }
        return args[i]
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--bench-dir": cfg.benchDir = URL(fileURLWithPath: next())
        case "--ids": cfg.ids = Set(next().split(separator: ",").map(String.init))
        case "--reps": cfg.reps = Int(next()) ?? 3
        case "--taps": cfg.taps = Int(next()) ?? 4
        case "--jobs": cfg.jobs = Int(next()) ?? 2
        default:
            if let m = Method(rawValue: a) { cfg.methods.append(m) } else { usage() }
        }
        i += 1
    }
    return (command, cfg)
}

let (command, cfg) = parseArgs()

func corpus() throws -> [CorpusItem] {
    try loadCorpus(benchDir: cfg.benchDir).filter { cfg.ids.isEmpty || cfg.ids.contains($0.id) }
}

func fmt(_ x: Double, _ d: Int = 2) -> String {
    x.isNaN ? "nan" : String(format: "%.\(d)f", x)
}

func appendLine(_ line: String, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    try h.seekToEnd()
    try h.write(contentsOf: Data((line + "\n").utf8))
}

func outURL(_ name: String, _ size: Int, _ id: String) -> URL {
    cfg.out.appendingPathComponent("\(name)/\(size)/\(id).png")
}

func runInfo() throws {
    for it in try corpus() {
        let s = try sourceInfo(it.url)
        let mp = Double(s.width * s.height) / 1e6
        print("\(it.id)\t\(it.category)\t\(s.width)x\(s.height)\t\(fmt(mp, 1))MP\t\(s.profile)\torient=\(s.orientation)")
    }
}

func runSelftest() throws {
    let err = try gammaRoundTripMaxError()
    print("method C gamma round trip (vImage sRGB decode+encode, 8-bit): max abs error = \(err) codes")
    if err > 1 { throw BenchError("round trip error too large") }
}

func runRef() throws {
    for it in try corpus() {
        let info = try sourceInfo(it.url)
        var src: Pixels?
        for size in sizes {
            guard let (w, h) = targetSize(width: info.width, height: info.height, longEdge: size)
            else { continue }
            let dest = outURL("ref", size, it.id)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            if src == nil { src = try decodeSRGB8(it.url) }
            let t0 = wallNs()
            let r = referenceDownscale(src!, width: w, height: h, taps: cfg.taps)
            try writePNG(r, to: dest)
            print("ref \(it.id) \(size) \(w)x\(h) \(fmt(Double(wallNs() - t0) / 1e9, 1))s")
        }
    }
}

func runTime() throws {
    guard let method = cfg.methods.first else { usage() }
    // A filtered run (--ids) must not clobber the full sweep's CSV or outputs' record.
    let csv = cfg.out.appendingPathComponent(
        cfg.ids.isEmpty ? "time-\(method.rawValue).csv" : "time-subset-\(method.rawValue).csv")
    try FileManager.default.createDirectory(at: cfg.out, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: csv)
    try appendLine(
        "method,size,category,id,out_w,out_h,dims_ok,decode_ms,decode_cpu_ms,op_ms,op_cpu_ms", to: csv)
    for it in try corpus() {
        let info = try sourceInfo(it.url)
        var src: Pixels?
        var decMs = 0.0, decCpu = 0.0
        if method != .A {
            _ = try decodeSRGB8(it.url)  // warm-up (file cache, ImageIO setup)
            var w: [Double] = [], c: [Double] = []
            for _ in 0..<cfg.reps {
                let (wm, cm, p) = try timed { try decodeSRGB8(it.url) }
                w.append(wm); c.append(cm); src = p
            }
            decMs = median(w); decCpu = median(c)
        }
        for size in sizes {
            guard let (ew, eh) = targetSize(width: info.width, height: info.height, longEdge: size)
            else { continue }
            let run: () throws -> Pixels = {
                switch method {
                case .A: return try resizeA(url: it.url, longEdge: size)
                case .B: return try resizeB(src!, width: ew, height: eh)
                case .C: return try resizeC(src!, width: ew, height: eh)
                case .D: return try resizeD(src!, width: ew, height: eh)
                }
            }
            _ = try run()  // warm-up
            var w: [Double] = [], c: [Double] = []
            var last: Pixels?
            for _ in 0..<cfg.reps {
                let (wm, cm, p) = try timed(run)
                w.append(wm); c.append(cm); last = p
            }
            let out = last!
            let ok = (out.width == ew && out.height == eh) ? 1 : 0
            try writePNG(out, to: outURL(method.rawValue, size, it.id))
            try appendLine(
                "\(method.rawValue),\(size),\(it.category),\(it.id),\(out.width),\(out.height),\(ok),\(fmt(decMs, 3)),\(fmt(decCpu, 3)),\(fmt(median(w), 3)),\(fmt(median(c), 3))",
                to: csv)
            print("\(method.rawValue) \(it.id) \(size) \(out.width)x\(out.height) dec=\(fmt(decMs, 1))ms op=\(fmt(median(w), 1))ms cpu=\(fmt(median(c), 1))ms")
        }
    }
}

func runScore() throws {
    let bin = cfg.benchDir.appendingPathComponent(".tools/bin")
    let csv = cfg.out.appendingPathComponent("scores.csv")
    var done = Set<String>()
    if let s = try? String(contentsOf: csv, encoding: .utf8) {
        for l in s.split(separator: "\n").dropFirst() { done.insert(l.split(separator: ",").prefix(4).joined(separator: ",")) }
    } else {
        try appendLine("method,size,category,id,ssimulacra2,butteraugli", to: csv)
    }
    // Where ImageIO's thumbnail is 1 px off the reference size, build an alternate reference at
    // that exact size so the pair is still comparable (ref-alt/<size>/<id>.png).
    let corp = try corpus()
    for r in readCSV(cfg.out.appendingPathComponent("time-A.csv")) where r["dims_ok"] == "0" {
        guard let id = r["id"], let size = Int(r["size"] ?? ""), let w = Int(r["out_w"] ?? ""),
            let h = Int(r["out_h"] ?? ""), let it = corp.first(where: { $0.id == id })
        else { continue }
        let dest = outURL("ref-alt", size, id)
        if FileManager.default.fileExists(atPath: dest.path) { continue }
        let src = try decodeSRGB8(it.url)
        try writePNG(referenceDownscale(src, width: w, height: h, taps: cfg.taps), to: dest)
        print("ref-alt \(id) \(size) \(w)x\(h)")
    }
    struct Job: Sendable { let m: String; let size: Int; let cat: String; let id: String }
    var jobs: [Job] = []
    let items = try corpus()
    for m in (cfg.methods.isEmpty ? Method.allCases : cfg.methods) {
        for size in sizes {
            for it in items where FileManager.default.fileExists(atPath: outURL(m.rawValue, size, it.id).path) {
                if !done.contains("\(m.rawValue),\(size),\(it.category),\(it.id)") {
                    jobs.append(Job(m: m.rawValue, size: size, cat: it.category, id: it.id))
                }
            }
        }
    }
    let workers = max(1, cfg.jobs)
    let jobList = jobs
    let outDir = cfg.out
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        var k = w
        while k < jobList.count {
            let j = jobList[k]
            var ref = outDir.appendingPathComponent("ref/\(j.size)/\(j.id).png")
            let alt = outDir.appendingPathComponent("ref-alt/\(j.size)/\(j.id).png")
            if j.m == "A", FileManager.default.fileExists(atPath: alt.path) { ref = alt }
            let dist = outDir.appendingPathComponent("\(j.m)/\(j.size)/\(j.id).png")
            let s = Tools.score(tool: "ssimulacra2", binDir: bin, ref: ref, dist: dist)
            let b = Tools.score(tool: "butteraugli_main", binDir: bin, ref: ref, dist: dist)
            let line = "\(j.m),\(j.size),\(j.cat),\(j.id),\(fmt(s, 4)),\(fmt(b, 4))"
            lock.lock()
            try? appendLine(line, to: csv)
            print(line)
            lock.unlock()
            k += workers
        }
    }
}

func readCSV(_ url: URL) -> [[String: String]] {
    guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let lines = s.split(separator: "\n").map(String.init)
    guard let head = lines.first?.split(separator: ",").map(String.init) else { return [] }
    return lines.dropFirst().map { l in
        Dictionary(uniqueKeysWithValues: zip(head, l.split(separator: ",", omittingEmptySubsequences: false).map(String.init)))
    }
}

func runReport() throws {
    var times: [[String: String]] = []
    for m in Method.allCases { times += readCSV(cfg.out.appendingPathComponent("time-\(m.rawValue).csv")) }
    let scores = readCSV(cfg.out.appendingPathComponent("scores.csv"))
    func d(_ r: [String: String], _ k: String) -> Double { Double(r[k] ?? "") ?? .nan }
    let cats = ["photo", "screenshot"]
    print("| size | category | method | n | SSIMULACRA2 median (min) | Butteraugli median (max) | op ms median | decode ms | total ms | CPU/wall |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for size in sizes {
        for cat in cats {
            for m in Method.allCases {
                let t = times.filter { $0["method"] == m.rawValue && $0["size"] == "\(size)" && $0["category"] == cat }
                let s = scores.filter { $0["method"] == m.rawValue && $0["size"] == "\(size)" && $0["category"] == cat }
                guard !t.isEmpty else { continue }
                let ss = s.map { d($0, "ssimulacra2") }.filter { !$0.isNaN }
                let bb = s.map { d($0, "butteraugli") }.filter { !$0.isNaN }
                let op = median(t.map { d($0, "op_ms") })
                let dec = m == .A ? Double.nan : median(t.map { d($0, "decode_ms") })
                let tot = median(t.map { d($0, "op_ms") + (m == .A ? 0 : d($0, "decode_ms")) })
                let cpu = median(t.map { d($0, "op_cpu_ms") / d($0, "op_ms") })
                print("| \(size) | \(cat) | \(m.rawValue) | \(t.count) | \(fmt(median(ss), 2)) (\(fmt(ss.min() ?? .nan, 1))) | \(fmt(median(bb), 3)) (\(fmt(bb.max() ?? .nan, 2))) | \(fmt(op, 0)) | \(m == .A ? "-" : fmt(dec, 0)) | \(fmt(tot, 0)) | \(fmt(cpu, 2)) |")
            }
        }
    }
    // Paired per-image differences.
    print("\nPaired per-image SSIMULACRA2 difference (first minus second), median [wins of first / n]:\n")
    print("| size | category | pair | median diff | first wins |")
    print("|---|---|---|---|---|")
    let pairs = [("C", "B"), ("C", "A"), ("A", "B"), ("C", "D"), ("B", "D")]
    var lookup: [String: Double] = [:]
    for r in scores { lookup["\(r["method"]!),\(r["size"]!),\(r["id"]!)"] = d(r, "ssimulacra2") }
    for size in sizes {
        for cat in cats {
            let ids = Set(scores.filter { $0["size"] == "\(size)" && $0["category"] == cat }.compactMap { $0["id"] })
            for (x, y) in pairs {
                var diffs: [Double] = []
                for id in ids.sorted() {
                    if let a = lookup["\(x),\(size),\(id)"], let b = lookup["\(y),\(size),\(id)"], !a.isNaN, !b.isNaN {
                        diffs.append(a - b)
                    }
                }
                if diffs.isEmpty { continue }
                print("| \(size) | \(cat) | \(x)-\(y) | \(fmt(median(diffs), 2)) | \(diffs.filter { $0 > 0 }.count)/\(diffs.count) |")
            }
        }
    }
    let bad = times.filter { $0["dims_ok"] == "0" }
    print("\nOutputs whose size differs from the reference size: \(bad.count)")
    for r in bad { print("- \(r["method"]!) \(r["size"]!) \(r["id"]!) -> \(r["out_w"]!)x\(r["out_h"]!)") }
}

do {
    switch command {
    case "info": try runInfo()
    case "selftest": try runSelftest()
    case "ref": try runRef()
    case "time": try runTime()
    case "score": try runScore()
    case "report": try runReport()
    default: usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
