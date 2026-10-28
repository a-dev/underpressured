import Foundation

enum Tools {
    static func run(_ exe: URL, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// First number in a tool's stdout.
    static func firstNumber(_ s: String) -> Double? {
        guard let r = s.range(of: #"-?\d+(\.\d+)?([eE][-+]?\d+)?"#, options: .regularExpression)
        else { return nil }
        return Double(s[r])
    }

    static func score(tool: String, binDir: URL, ref: URL, dist: URL) -> Double {
        guard let (st, out) = try? run(binDir.appendingPathComponent(tool), [ref.path, dist.path]),
            st == 0, let v = firstNumber(out)
        else { return .nan }
        return v
    }
}

final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ x: T) { lock.lock(); items.append(x); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}
