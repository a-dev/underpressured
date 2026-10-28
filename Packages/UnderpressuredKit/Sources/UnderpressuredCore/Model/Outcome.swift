import Foundation

/// How an Item ended (GLOSSARY: Outcome).
public enum Outcome: Sendable, Hashable {
    /// `output` is where the result was written: the source's own path, or a new one (§6.1–6.3).
    case optimized(Savings, notes: [Note], output: URL)
    /// `output` is set only when a copy was written into an Export folder (§6.2).
    case skipped(SkipReason, notes: [Note], output: URL? = nil)
    case failed(FailReason)
    case cancelled
}

/// The original size minus the new size.
public struct Savings: Sendable, Hashable {
    public var originalBytes: Int64
    public var newBytes: Int64

    public init(originalBytes: Int64, newBytes: Int64) {
        self.originalBytes = originalBytes
        self.newBytes = newBytes
    }

    public var bytes: Int64 { originalBytes - newBytes }

    /// Percentage of the original, 0 for an empty original.
    public var percent: Double {
        originalBytes == 0 ? 0 : Double(bytes) / Double(originalBytes) * 100
    }
}

/// Extra information shown next to an Outcome (spec §6.2, §7.3, §7.4).
public enum Note: Sendable, Hashable {
    case hdrRemoved
    case keptFullColor
    case reencodedVisuallyLossless
    case sourceCleanupFailed
    case copiedUnchanged
    /// Long-edge pixel counts, e.g. "resized 4032 → 2048" (§7.3 step 5).
    case resized(from: Int, to: Int)
}

/// Why an Item was Skipped (spec §7.8).
public enum SkipReason: Sendable, Hashable {
    case alreadyOptimal
    case alreadyOptimized
    case alreadyInQueue
    case cantWriteYet(ImageFormat)
    case unsupported(UnsupportedKind)

    /// Stable English-only identifier for logs and diagnostics.
    public var diagnosticID: String {
        switch self {
        case .alreadyOptimal: return "already_optimal"
        case .alreadyOptimized: return "already_optimized"
        case .alreadyInQueue: return "already_in_queue"
        case .cantWriteYet(let format):
            let formatID: String
            switch format {
            case .jpeg: formatID = "jpeg"
            case .png: formatID = "png"
            case .heic: formatID = "heic"
            case .webp: formatID = "webp"
            case .tiff: formatID = "tiff"
            case .avif: formatID = "avif"
            case .jpegXL: formatID = "jpeg_xl"
            }
            return "cant_write_yet.\(formatID)"
        case .unsupported(let kind): return "unsupported.\(kind.diagnosticID)"
        }
    }
    /// Already-optimal and already-optimized Items are copied into an Export folder (§6.2).
    public var copiesToExportFolder: Bool {
        self == .alreadyOptimal || self == .alreadyOptimized
    }
}

/// An image the app recognises but won't process (spec §7.2).
public enum UnsupportedKind: Sendable, Hashable {
    case animated
    case multiPageTIFF
    case raw
    case gif
    case otherType

    /// Stable English-only identifier for logs and diagnostics.
    public var diagnosticID: String {
        switch self {
        case .animated: "animated"
        case .multiPageTIFF: "multi_page_tiff"
        case .raw: "raw"
        case .gif: "gif"
        case .otherType: "other_type"
        }
    }
}

/// Why an Item Failed (spec §7.8).
public enum FailReason: Sendable, Hashable, CaseIterable {
    case cantRead
    case noPermission
    case fileNotFound
    case fileAlreadyExists
    case fileIOFailed
    case diskFull
    case noTrash
    case exportFolderUnavailable
    case destinationChanged
    case fileChanged
    case encodeFailed
    case losslessEncoderUnavailable

    /// Stable English-only identifier for logs and diagnostics.
    public var diagnosticID: String {
        switch self {
        case .cantRead: "cant_read"
        case .fileNotFound: "file_not_found"
        case .fileAlreadyExists: "file_already_exists"
        case .fileIOFailed: "file_io_failed"
        case .noPermission: "no_permission"
        case .diskFull: "disk_full"
        case .noTrash: "no_trash"
        case .exportFolderUnavailable: "export_folder_unavailable"
        case .destinationChanged: "destination_changed"
        case .fileChanged: "file_changed"
        case .encodeFailed: "encode_failed"
        case .losslessEncoderUnavailable: "lossless_encoder_unavailable"
        }
    }
}
