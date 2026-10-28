import Foundation

/// Locates bench/.tools/bin: $UPBENCH_TOOLS, else the nearest `.tools/bin` found
/// walking up from the executable's directory, then from the cwd.
struct Tools: Sendable {
    let dir: URL

    init() throws {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["UPBENCH_TOOLS"], !env.isEmpty {
            dir = URL(fileURLWithPath: env)
            return
        }
        var starts: [URL] = []
        if let exe = Bundle.main.executableURL {
            starts.append(exe.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        starts.append(URL(fileURLWithPath: fm.currentDirectoryPath))
        for start in starts {
            var d = start
            for _ in 0..<12 {
                let cand = d.appendingPathComponent(".tools/bin")
                if fm.fileExists(atPath: cand.path) { dir = cand; return }
                let parent = d.deletingLastPathComponent()
                if parent == d { break }
                d = parent
            }
        }
        throw BenchError("cannot find .tools/bin; set UPBENCH_TOOLS")
    }

    func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
}
