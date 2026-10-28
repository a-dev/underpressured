import Foundation

struct Metrics: Sendable {
    let tools: Tools

    /// First number in the tool's stdout.
    static func firstNumber(_ s: String) -> Double? {
        guard let r = s.range(of: #"-?\d+(\.\d+)?([eE][-+]?\d+)?"#, options: .regularExpression) else { return nil }
        return Double(s[r])
    }

    private func score(_ tool: String, _ ref: URL, _ dist: URL, work: URL) async throws -> Double {
        let r = try await runProcess(tools.url(tool), [ref.path, dist.path], scratch: work)
        guard r.status == 0, let v = Metrics.firstNumber(r.stdout) else {
            throw BenchError("\(tool) failed (exit \(r.status)): \(r.stderr.prefix(200)) \(r.stdout.prefix(100))")
        }
        return v
    }

    func ssimulacra2(_ ref: URL, _ dist: URL, work: URL) async throws -> Double {
        try await score("ssimulacra2", ref, dist, work: work)
    }

    func butteraugli(_ ref: URL, _ dist: URL, work: URL) async throws -> Double {
        try await score("butteraugli_main", ref, dist, work: work)
    }
}
