import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    /// Wall time from launch to exit, in milliseconds (includes process spawn).
    let wallMs: Double
}

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Runs a subprocess without blocking a cooperative thread. stdout/stderr go to
/// temp files (no pipe-buffer deadlocks, no reader threads).
func runProcess(_ exe: URL, _ args: [String], scratch: URL) async throws -> ProcessResult {
    let id = UUID().uuidString
    let outURL = scratch.appendingPathComponent("\(id).out")
    let errURL = scratch.appendingPathComponent("\(id).err")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    defer {
        try? FileManager.default.removeItem(at: outURL)
        try? FileManager.default.removeItem(at: errURL)
    }
    let outH = try FileHandle(forWritingTo: outURL)
    let errH = try FileHandle(forWritingTo: errURL)
    defer { try? outH.close(); try? errH.close() }

    let p = Process()
    p.executableURL = exe
    p.arguments = args
    p.standardOutput = outH
    p.standardError = errH
    p.standardInput = FileHandle.nullDevice

    let clock = ContinuousClock()
    let start = clock.now
    let status: Int32 = try await withCheckedThrowingContinuation { cont in
        p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus) }
        do { try p.run() } catch { cont.resume(throwing: error) }
    }
    let elapsed = clock.now - start
    let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15

    let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
    let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
    return ProcessResult(status: status, stdout: out, stderr: err, wallMs: ms)
}
