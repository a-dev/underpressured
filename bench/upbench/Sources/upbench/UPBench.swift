import Foundation

let usage = """
usage: upbench --encoder <\(EncoderKind.allCases.map(\.rawValue).joined(separator: "|"))> \
(--quality N | --match-ssimulacra2 T) --input <dir or files...> --out <csv> [--jobs N]
       upbench engine --input <dir or files...> --out <csv> [--presets a,b,...]   (real ImageEngine, Phase 4)
env: UPBENCH_TOOLS overrides the tool directory (default: nearest .tools/bin above the executable/cwd)
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("upbench: \(msg)\n\(usage)\n".utf8))
    exit(2)
}

@main
struct UPBench {
    static func main() async {
        await run()
    }
}

func run() async {
    if CommandLine.arguments.dropFirst().first == "engine" {
        await EngineMode.run(Array(CommandLine.arguments.dropFirst(2)))
        return
    }
    var encoderName: String?
    var quality: Int?
    var target: Double?
    var inputs: [String] = []
    var outPath: String?
    var jobs = 1

    var args = Array(CommandLine.arguments.dropFirst())[...]
    func value(_ flag: String) -> String {
        guard let v = args.popFirst() else { fail("\(flag) needs a value") }
        return v
    }
    while let a = args.popFirst() {
        switch a {
        case "--encoder": encoderName = value(a)
        case "--quality": guard let q = Int(value(a)), (1...100).contains(q) else { fail("--quality must be 1...100") }; quality = q
        case "--match-ssimulacra2": guard let t = Double(value(a)) else { fail("bad target") }; target = t
        case "--out": outPath = value(a)
        case "--jobs": guard let j = Int(value(a)), j >= 1 else { fail("--jobs must be >= 1") }; jobs = j
        case "--input":
            while let n = args.first, !n.hasPrefix("--") { inputs.append(n); args.removeFirst() }
        case "-h", "--help": print(usage); exit(0)
        default: fail("unknown argument \(a)")
        }
    }
    guard let encoderName, let kind = EncoderKind(rawValue: encoderName) else { fail("missing/unknown --encoder") }
    guard let outPath else { fail("missing --out") }
    guard !inputs.isEmpty else { fail("missing --input") }
    let mode: Mode
    switch (quality, target) {
    case (let q?, nil): mode = .fixed(quality: q)
    case (nil, let t?): mode = .matchSSIMULACRA2(target: t)
    default: fail("give exactly one of --quality or --match-ssimulacra2")
    }

    let exts: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "webp", "bmp", "gif"]
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
    guard !files.isEmpty else { fail("no input images found") }

    let tools: Tools
    do { tools = try Tools() } catch { fail("\(error)") }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("upbench-\(UUID().uuidString)")
    do { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) } catch { fail("\(error)") }

    let runner = Runner(encoder: kind.make(tools: tools), metrics: Metrics(tools: tools), mode: mode, work: work)
    let inputFiles = files
    let jobCount = jobs

    let rows: [Row] = await withTaskGroup(of: (Int, Row).self) { group in
        var results = [Row?](repeating: nil, count: inputFiles.count)
        var next = 0
        func addNext() {
            guard next < inputFiles.count else { return }
            let i = next, f = inputFiles[i]
            next += 1
            group.addTask { (i, await runner.process(f)) }
        }
        for _ in 0..<min(jobCount, inputFiles.count) { addNext() }
        while let (i, row) = await group.next() {
            results[i] = row
            FileHandle.standardError.write(Data("[\(i + 1)/\(inputFiles.count)] \(row.csv)\n".utf8))
            addNext()
        }
        return results.compactMap { $0 }
    }

    try? FileManager.default.removeItem(at: work)
    let csv = ([Row.header] + rows.filter { $0.error == nil }.map(\.csv)).joined(separator: "\n") + "\n"
    let outURL = URL(fileURLWithPath: outPath)
    try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    do { try csv.write(to: outURL, atomically: true, encoding: .utf8) } catch { fail("cannot write \(outPath): \(error)") }
    let failed = rows.filter { $0.error != nil }.count
    if failed > 0 { FileHandle.standardError.write(Data("upbench: \(failed) file(s) failed\n".utf8)); exit(1) }

}