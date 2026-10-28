import UnderpressuredCore
import Foundation
import os

/// Logs each Item and error to Console.app. Diagnostics do not appear in the UI.
enum PipelineLog {
    static let logger = Logger(subsystem: "app.underpressured.Underpressured", category: "pipeline")

    /// One entry per Item. The source path is private; `.failed` logs at error level, the rest at info.
    static func item(source: URL, outcome: Outcome, bytesBefore: Int64?, bytesAfter: Int64?, milliseconds: Int) {
        let fields = message(outcome: outcome, bytesBefore: bytesBefore, bytesAfter: bytesAfter, milliseconds: milliseconds)
        let path = source.path(percentEncoded: false)
        switch outcome {
        case .failed:
            logger.error("source=\(path, privacy: .private) \(fields, privacy: .public)")
        case .optimized, .skipped, .cancelled:
            logger.info("source=\(path, privacy: .private) \(fields, privacy: .public)")
        }
    }

    /// One entry per error. The stage is omitted when the caller doesn't know it.
    static func error(source: URL, stage: Stage?, message: String) {
        let path = source.path(percentEncoded: false)
        let stageName = stage.map { String(describing: $0) } ?? "none"
        logger.error(
            "source=\(path, privacy: .private) stage=\(stageName, privacy: .public) error=\"\(message, privacy: .public)\"")
    }

    /// The public part of an Item entry: outcome kind, reason, bytes before and after, and milliseconds.
    static func message(outcome: Outcome, bytesBefore: Int64?, bytesAfter: Int64?, milliseconds: Int) -> String {
        let kind: String
        var reason = "-"
        switch outcome {
        case .optimized:
            kind = "optimized"
        case .skipped(let skip, _, _):
            kind = "skipped"
            reason = skip.diagnosticID
        case .failed(let fail):
            kind = "failed"
            reason = fail.diagnosticID
        case .cancelled:
            kind = "cancelled"
        }
        let before = bytesBefore.map { String($0) } ?? "-"
        let after = bytesAfter.map { String($0) } ?? "-"
        return "outcome=\(kind) reason=\"\(reason)\" bytes=\(before)->\(after) ms=\(milliseconds)"
    }
}
