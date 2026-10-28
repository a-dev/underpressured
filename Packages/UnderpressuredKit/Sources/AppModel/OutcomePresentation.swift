import UnderpressuredApplication
import Foundation
import UnderpressuredCore

/// Localized wording for outcome details shown by the app.
public extension Note {
    var message: String {
        switch self {
        case .hdrRemoved:
            String(localized: "HDR removed", bundle: .module, comment: "Outcome note shown when HDR metadata was removed.")
        case .keptFullColor:
            String(localized: "kept full color", bundle: .module, comment: "Outcome note shown when the image kept full color.")
        case .reencodedVisuallyLossless:
            String(localized: "re-encoded at visually lossless quality", bundle: .module, comment: "Outcome note shown when an image was re-encoded without visible quality loss.")
        case .sourceCleanupFailed:
            String(localized: "Output saved; couldn’t remove the original", bundle: .module, comment: "Outcome note shown when output was saved but the original could not be removed.")
        case .copiedUnchanged:
            String(localized: "copied unchanged", bundle: .module, comment: "Outcome note shown when a copy was made without changing the image.")
        case .resized(let from, let to):
            String(localized: "resized \(from.formatted()) → \(to.formatted())", bundle: .module, comment: "Outcome note showing the original and new long-edge pixel counts.")
        }
    }

    /// Wording for VoiceOver. Numeric counts are formatted for the user's locale.
    var spokenMessage: String {
        switch self {
        case .resized(let from, let to):
            String(localized: "note.resized.spoken", defaultValue: "resized from \(from.formatted()) to \(to) pixels", bundle: .module, comment: "Spoken resize: formatted original long edge, then numeric new long edge. Plural varies with the second argument, the new pixel count.")
        default:
            message
        }
    }
}

public extension SkipReason {
    var message: String {
        switch self {
        case .alreadyOptimal:
            String(localized: "Already optimal", bundle: .module, comment: "Skip reason shown when an image is already optimal.")
        case .alreadyOptimized:
            String(localized: "Already optimized with these settings", bundle: .module, comment: "Skip reason shown when an image was already optimized with the active settings.")
        case .alreadyInQueue:
            String(localized: "Already in the queue", bundle: .module, comment: "Skip reason shown when the image is already in the queue.")
        case .cantWriteYet(let format):
            String(localized: "Can't write \(format.displayName) yet. Choose JPEG or PNG to convert", bundle: .module, comment: "Skip reason shown when the app cannot write the source image format; the format name is interpolated.")
        case .unsupported(let kind):
            String(localized: "Unsupported: \(kind.label)", bundle: .module, comment: "Skip reason shown for an image type the app does not support; the image type is interpolated.")
        }
    }
}

public extension UnsupportedKind {
    var label: String {
        switch self {
        case .animated:
            String(localized: "animated image", bundle: .module, comment: "Image type label for an animated image.")
        case .multiPageTIFF:
            String(localized: "multi-page TIFF", bundle: .module, comment: "Image type label for a multi-page TIFF file.")
        case .raw:
            String(localized: "RAW", bundle: .module, comment: "Image type label for RAW images.")
        case .gif:
            String(localized: "GIF", bundle: .module, comment: "Image type label for GIF images.")
        case .otherType:
            String(localized: "another type", bundle: .module, comment: "Image type label for another unsupported type.")
        }
    }
}

public extension FailReason {
    var message: String {
        switch self {
        case .cantRead:
            String(localized: "Can't read this image", bundle: .module, comment: "Failure reason shown when an image cannot be read.")
        case .fileNotFound:
            String(localized: "File or folder no longer exists", bundle: .module, comment: "File operation failure; a required path is missing.")
        case .fileAlreadyExists:
            String(localized: "A file already exists at the destination", bundle: .module, comment: "File operation failure; an occupied destination was not overwritten.")
        case .fileIOFailed:
            String(localized: "Couldn’t complete the file operation", bundle: .module, comment: "Safe generic message for an unexpected filesystem failure.")
        case .noPermission:
            String(localized: "No permission to access this file or folder", bundle: .module, comment: "Failure reason shown when the app lacks permission to read or write the path.")
        case .diskFull:
            String(localized: "Not enough disk space", bundle: .module, comment: "Failure reason shown when there is not enough disk space.")
        case .noTrash:
            String(localized: "No Trash on this volume", bundle: .module, comment: "Failure reason shown when this volume has no Trash.")
        case .exportFolderUnavailable:
            String(localized: "Export folder unavailable", bundle: .module, comment: "Failure reason shown when the export folder is unavailable.")
        case .destinationChanged:
            String(localized: "Destination changed while processing", bundle: .module, comment: "Failure reason shown when the destination changes during processing.")
        case .fileChanged:
            String(localized: "File changed while processing", bundle: .module, comment: "Failure reason shown when the source file changes during processing.")
        case .encodeFailed:
            String(localized: "Couldn't encode this image (codec error)", bundle: .module, comment: "Failure reason shown when image encoding fails.")
        case .losslessEncoderUnavailable:
            String(localized: "Couldn’t preserve Lossless JPEG quality. Source unchanged. Retry, or turn off Lossless to allow lossy encoding", bundle: .module, comment: "Failure reason shown when the lossless JPEG encoder is unavailable; the source remains unchanged.")
        }
    }
}
