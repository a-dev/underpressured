import MacPlatform
import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageEngine
import ImageIO
import LocalFileSystem
import Synchronization
import UniformTypeIdentifiers
import UnderpressuredCore

// Stress-tests the real Queue, Pipeline, file system, and native codecs with random cancellation.
// Checks temporary files, partial files, stuck Items, and peak memory.
//
// Benchmark: SoakHarness --bench --root <folder> [--count N] [--runs N]
// Usage: SoakHarness --root <empty folder> [--small N] [--large N] [--rounds N] [--memory-limit-mb N]
//        [--hold-seconds N]  (keep the process alive at settled idle so heap/vmmap/leaks can attach)

// MARK: Arguments

struct Config {
    var root: URL
    var small = 10_000
    var large = 100
    /// Rounds that are cancelled at a random moment, followed by one round that runs to the end.
    var cancelledRounds = 6
    /// Allows 3.6 GB for the 120 MP pixel budget at about 30 bytes per pixel.
    /// Adds 1.5 GB for baseline memory, file data, and allocation overhead.
    var memoryLimitMB = 5_120
    var holdSeconds = 0
}

func parseArguments() -> Config {
    var config = Config(root: URL(fileURLWithPath: "/nonexistent"))
    var rootGiven = false
    var args = CommandLine.arguments.dropFirst()
    while let flag = args.popFirst() {
        guard let value = args.popFirst() else { fatalError("missing value for \(flag)") }
        switch flag {
        case "--root": config.root = URL(fileURLWithPath: value).resolvingSymlinksInPath(); rootGiven = true
        case "--small": config.small = Int(value)!
        case "--large": config.large = Int(value)!
        case "--rounds": config.cancelledRounds = Int(value)!
        case "--memory-limit-mb": config.memoryLimitMB = Int(value)!
        case "--hold-seconds": config.holdSeconds = Int(value)!
        default: fatalError("unknown flag \(flag)")
        }
    }
    precondition(rootGiven, "--root is required")
    return config
}

// MARK: Reporting

let failures = Mutex(0)

func report(_ ok: Bool, _ name: String, _ detail: String) {
    print("\(ok ? "PASS" : "FAIL") \(name): \(detail)")
    if !ok { failures.withLock { $0 += 1 } }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[soak] \(message)\n".utf8))
}

// MARK: Peak memory

/// The process's physical footprint (what Activity Monitor and `footprint` report), in bytes.
func physFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

final class PeakSampler: @unchecked Sendable {
    private let peak = Mutex(0)
    private let running = Mutex(true)

    func start() {
        let thread = Thread { [self] in
            while running.withLock({ $0 }) {
                let now = physFootprint()
                peak.withLock { $0 = max($0, now) }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        thread.start()
    }

    func stop() -> Int {
        running.withLock { $0 = false }
        Thread.sleep(forTimeInterval: 0.05)
        return peak.withLock { $0 }
    }
}

// MARK: Image generation

/// A smooth gradient with light noise, so it compresses to a few MB even at 48 MP.
func makeImage(width: Int, height: Int, seed: UInt64) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let stride = context.bytesPerRow
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    var state = seed
    for y in 0..<height {
        let row = pixels + y * stride
        for x in 0..<width {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Int((state >> 62) & 0x3)
            let offset = x * 4
            row[offset] = UInt8(truncatingIfNeeded: (x * 255 / width) + noise)
            row[offset + 1] = UInt8(truncatingIfNeeded: (y * 255 / height) + noise)
            row[offset + 2] = UInt8(truncatingIfNeeded: ((x + y) * 255 / (width + height)) + noise)
            row[offset + 3] = 255
        }
    }
    return context.makeImage()!
}

func encode(_ image: CGImage, as type: UTType, quality: Double = 0.92) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

// MARK: Folder checks

func allFiles(in folder: URL) -> [URL] {
    let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
    return (enumerator?.allObjects as? [URL]) ?? []
}

/// A complete decode of a small file; a scaled full decode of a large one (a truncated stream fails).
func decodesCompletely(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetStatus(source) == .statusComplete
    else { return false }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 256,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
}


// MARK: Benchmark (plan 6.7, spec §8 performance target)

/// Photo-like content: smooth structure plus per-pixel noise of about +-12 levels, so JPEG does real work.
func makePhotoLikeImage(width: Int, height: Int, seed: UInt64) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let stride = context.bytesPerRow
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    var state = seed
    let phase = Double(seed % 97)
    for y in 0..<height {
        let row = pixels + y * stride
        let fy = Double(y) / Double(height)
        for x in 0..<width {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Int((state >> 59) & 0x1F) - 16
            let fx = Double(x) / Double(width)
            let base = 128 + 70 * sin(fx * 9 + phase) * cos(fy * 7 + phase * 0.3)
            let r = base + 50 * fx
            let g = base * 0.8 + 60 * fy + 20 * sin((fx + fy) * 40)
            let b = 255 - base * 0.7 + 25 * sin(fx * 90) * sin(fy * 70)
            row[x * 4] = UInt8(max(0, min(255, Int(r) + noise)))
            row[x * 4 + 1] = UInt8(max(0, min(255, Int(g) + noise)))
            row[x * 4 + 2] = UInt8(max(0, min(255, Int(b) + noise)))
            row[x * 4 + 3] = 255
        }
    }
    return context.makeImage()!
}

/// 100 photos of 12 MP, Web Preset (quality 80, max long edge 2048, no metadata), Export, timed enqueue -> idle.
func bench(root: URL, count: Int, runs: Int) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let masters = (0..<4).map { index -> URL in
        let url = root.appendingPathComponent("master-\(index).jpg")
        try! encode(makePhotoLikeImage(width: 4_000, height: 3_000, seed: UInt64(index + 1)), as: .jpeg, quality: 0.9).write(to: url)
        return url
    }
    let size = (try? masters[0].resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    log("bench: master JPEG ~\(size / 1024) KB, \(count) photos, \(runs) runs, parallelism \(PerformanceCores.count())")
    let settings = EffectiveSettings(quality: 80, lossless: false, resizeRule: .maxLongEdge(2_048), keepMetadata: false)
    for run in 1...runs {
        let folder = root.appendingPathComponent("photos-\(run)")
        let export = root.appendingPathComponent("export-\(run)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: export, withIntermediateDirectories: true)
        var sources: [URL] = []
        for i in 0..<count {
            let target = folder.appendingPathComponent("p\(i).jpg")
            try fm.copyItem(at: masters[i % masters.count], to: target)
            sources.append(target)
        }
        let pipeline = Pipeline(fileAccess: LocalFileAccess(), codec: NativeCodec())
        let queue = Queue(parallelism: PerformanceCores.count(), pipeline: pipeline.itemPipeline)
        var events = queue.events.makeAsyncIterator()
        let start = ContinuousClock.now
        await queue.enqueue(Batch(
            settings: settings, outputFormat: .original, destination: .exportFolder(export),
            items: sources.map { Item(source: $0, droppedRoot: folder) }))
        var failed = 0
        while let event = await events.next(), event != .idle {
            switch event {
            case .batchAdded(let batch):
                failed += batch.items.count { if case .finished(.failed) = $0.state { true } else { false } }
            case .itemChanged(_, _, .finished(.failed)): failed += 1
            default: break
            }
        }
        let elapsed = start.duration(to: .now)
        let outputs = allFiles(in: export).filter { $0.pathExtension == "jpg" }.count
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(String(format: "BENCH run %d: %.2f s (%d outputs, %d failed)", run, seconds, outputs, failed))
        try fm.removeItem(at: folder)
        try fm.removeItem(at: export)
    }
}

// MARK: Run

struct RoundResult {
    var stuck = 0
    var temporaries: [String] = []
    var partials: [String] = []
    var failedOutcomes = 0
    var counts: [String: Int] = [:]
}

func run() async throws {
    let config = parseArguments()
    let fm = FileManager.default
    try fm.createDirectory(at: config.root, withIntermediateDirectories: true)
    let started = ContinuousClock.now
    log("small=\(config.small) large=\(config.large) cancelled rounds=\(config.cancelledRounds) root=\(config.root.path)")

    // Masters are written once and cloned (APFS) into every round.
    let masters = config.root.appendingPathComponent("masters")
    try fm.createDirectory(at: masters, withIntermediateDirectories: true)
    var smallMasters: [URL] = []
    var largeMasters: [URL] = []
    for (index, size) in [(96, 64), (320, 240), (640, 480)].enumerated() {
        let image = makeImage(width: size.0, height: size.1, seed: UInt64(index + 1))
        let jpeg = masters.appendingPathComponent("small-\(index).jpg")
        try encode(image, as: .jpeg).write(to: jpeg)
        smallMasters.append(jpeg)
    }
    let png = masters.appendingPathComponent("small-png.png")
    try encode(makeImage(width: 48, height: 48, seed: 9), as: .png).write(to: png)
    smallMasters.append(png)
    if config.large > 0 {
        for (index, size) in [(8_000, 6_000), (6_928, 6_928)].enumerated() {  // both 48 MP
            let url = masters.appendingPathComponent("large-\(index).jpg")
            try encode(makeImage(width: size.0, height: size.1, seed: UInt64(100 + index)), as: .jpeg, quality: 0.85)
                .write(to: url)
            largeMasters.append(url)
        }
    }
    log("masters ready after \(started.duration(to: .now)), footprint \(physFootprint() / 1_048_576) MB")

    let files = LocalFileAccess()
    let settings = EffectiveSettings(quality: 75, lossless: false, resizeRule: .maxLongEdge(2_560), keepMetadata: false)
    let sampler = PeakSampler()
    sampler.start()

    var generator = SystemRandomNumberGenerator()
    var results: [RoundResult] = []
    var completedRounds: [RoundResult] = []
    // Cancelled rounds, then two that run to the end: one per Destination.
    let totalRounds = config.cancelledRounds + 2

    for round in 0..<totalRounds {
        let completes = round >= config.cancelledRounds
        let folder = config.root.appendingPathComponent("round-\(round)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Items: smalls and larges together, in a shuffled order per round.
        var sources: [URL] = []
        for i in 0..<config.small {
            let master = smallMasters[i % smallMasters.count]
            let target = folder.appendingPathComponent("s\(i).\(master.pathExtension)")
            try fm.copyItem(at: master, to: target)
            sources.append(target)
        }
        for i in 0..<config.large {
            let target = folder.appendingPathComponent("L\(i).jpg")
            try fm.copyItem(at: largeMasters[i % largeMasters.count], to: target)
            sources.append(target)
        }
        sources.shuffle(using: &generator)

        let replaces = completes ? round == config.cancelledRounds : round.isMultiple(of: 2)
        let destination: Destination = replaces
            ? .replaceOriginals(moveToTrash: false)
            : .exportFolder(config.root.appendingPathComponent("export-\(round)"))
        if case .exportFolder(let export) = destination {
            try fm.createDirectory(at: export, withIntermediateDirectories: true)
        }

        let pipeline = Pipeline(fileAccess: files, codec: NativeCodec())
        let queue = Queue(parallelism: PerformanceCores.count(), pipeline: pipeline.itemPipeline)
        var events = queue.events.makeAsyncIterator()
        await queue.enqueue(Batch(
            settings: settings, outputFormat: .original, destination: destination,
            items: sources.map { Item(source: $0, droppedRoot: folder) }))

        var delayText = "runs to the end"
        if !completes {
            // Log-uniform between 20 ms and 40 s, so cancels land early, mid-run and late.
            let seconds = 0.02 * pow(2_000.0, Double.random(in: 0..<1, using: &generator))
            delayText = String(format: "cancel after %.2fs", seconds)
            try await Task.sleep(for: .seconds(seconds))
            await queue.cancel()
        }
        let roundStart = ContinuousClock.now
        var result = RoundResult()
        var sourceByID: [Item.ID: URL] = [:]
        while let event = await events.next(), event != .idle {
            if case .batchAdded(let batch) = event {
                for item in batch.items {
                    sourceByID[item.id] = item.source
                    if case .finished(let outcome) = item.state {
                        let key = String(describing: outcome).prefix { $0 != "(" }
                        result.counts[String(key), default: 0] += 1
                        if case .failed = outcome {
                            result.failedOutcomes += 1
                            log("failed: \(item.source.lastPathComponent): \(outcome)")
                        }
                    }
                }
            }
            if case .itemChanged(_, let id, .finished(let outcome)) = event {
                let key = String(describing: outcome).prefix { $0 != "(" }
                result.counts[String(key), default: 0] += 1
                if case .failed = outcome {
                    result.failedOutcomes += 1
                    log("failed: \(sourceByID[id]?.lastPathComponent ?? id.uuidString): \(outcome)")
                }
            }
        }

        let afterIdle = physFootprint() / 1_048_576
        try await Task.sleep(for: .seconds(3))
        let settled = physFootprint() / 1_048_576
        result.stuck = (await queue.diagnostics).items
        let tree = allFiles(in: config.root).filter { !$0.path.hasPrefix(masters.path) }
        result.temporaries = tree.filter { $0.pathExtension == "tmp" }.map(\.lastPathComponent)
        let visible = tree.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        result.partials = visible.filter { !decodesCompletely($0) }.map(\.lastPathComponent)
        log("round \(round) (\(delayText)): \(result.counts) stuck=\(result.stuck) tmp=\(result.temporaries.count) "
            + "partial=\(result.partials.count) drain=\(roundStart.duration(to: .now)) "
            + "footprint at idle=\(afterIdle) MB, 3 s later=\(settled) MB")
        results.append(result)
        if completes { completedRounds.append(result) }

        try fm.removeItem(at: folder)
        if case .exportFolder(let export) = destination { try? fm.removeItem(at: export) }
    }

    let peak = sampler.stop()
    let peakMB = peak / 1_048_576
    let elapsed = started.duration(to: .now)

    let stuck = results.reduce(0) { $0 + $1.stuck }
    let temps = results.flatMap(\.temporaries)
    let partials = results.flatMap(\.partials)
    let cancelled = results.reduce(0) { $0 + ($1.counts["cancelled"] ?? 0) }
    let optimized = results.reduce(0) { $0 + ($1.counts["optimized"] ?? 0) }
    report(temps.isEmpty, "no temporary files", "\(temps.count) left over \(totalRounds) rounds \(temps.prefix(3))")
    report(partials.isEmpty, "no partial files", "\(partials.count) undecodable outputs \(partials.prefix(3))")
    report(stuck == 0, "no unfinished Items", "\(stuck) not finished; \(cancelled) cancelled, \(optimized) optimized in total")
    let completedFailed = completedRounds.reduce(0) { $0 + $1.failedOutcomes }
    let completedItems = completedRounds.reduce(0) { $0 + $1.counts.values.reduce(0, +) }
    report(completedFailed == 0 && !completedRounds.isEmpty, "completed runs have no failures",
           "\(completedFailed) failed of \(completedItems) Items in the replace and export runs")
    let allFailed = results.reduce(0) { $0 + $1.failedOutcomes }
    report(allFailed == 0, "no Item failed in any round (cancel must not fail Items)", "\(allFailed) failed; reasons are logged above")
    report(peakMB <= config.memoryLimitMB, "peak memory within budget",
           "peak footprint \(peakMB) MB, limit \(config.memoryLimitMB) MB (120 MP budget ~3.6 GB + 1.5 GB headroom)")
    print("runtime \(elapsed)")
    if config.holdSeconds > 0 {
        log("holding pid \(getpid()) for \(config.holdSeconds) s, footprint \(physFootprint() / 1_048_576) MB")
        try await Task.sleep(for: .seconds(config.holdSeconds))
        // Diagnostic only: the relief libmalloc applies on a memory-pressure notification.
        let before = physFootprint() / 1_048_576
        let released = malloc_zone_pressure_relief(nil, 0)
        log("pressure relief released \(released / 1_048_576) MB, footprint \(before) -> \(physFootprint() / 1_048_576) MB")
    }
}

if CommandLine.arguments.contains("--bench") {
    let args = CommandLine.arguments
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
    let root = URL(fileURLWithPath: value("--root") ?? "/nonexistent").resolvingSymlinksInPath()
    try await bench(root: root, count: Int(value("--count") ?? "") ?? 100, runs: Int(value("--runs") ?? "") ?? 3)
    exit(0)
}
try await run()
exit(failures.withLock { $0 } == 0 ? 0 : 1)
