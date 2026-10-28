import UnderpressuredApplication
import Testing
import UnderpressuredCore

@testable import AppModel

struct OutcomePresentationTests {
    @Test func skipReasons_haveReadablePresentation() {
        #expect(SkipReason.alreadyOptimal.message == "Already optimal")
        #expect(SkipReason.alreadyOptimized.message == "Already optimized with these settings")
        #expect(SkipReason.alreadyInQueue.message == "Already in the queue")
        #expect(SkipReason.unsupported(.animated).message == "Unsupported: animated image")
        #expect(SkipReason.unsupported(.multiPageTIFF).message == "Unsupported: multi-page TIFF")
        #expect(SkipReason.unsupported(.raw).message == "Unsupported: RAW")
        #expect(SkipReason.unsupported(.gif).message == "Unsupported: GIF")
        #expect(SkipReason.unsupported(.otherType).message == "Unsupported: another type")
        #expect(SkipReason.cantWriteYet(.heic).message == "Can't write HEIC yet. Choose JPEG or PNG to convert")
    }

    @Test func failReasons_haveReadablePresentation() {
        #expect(FailReason.cantRead.message == "Can't read this image")
        #expect(FailReason.noPermission.message == "No permission to access this file or folder")
        #expect(FailReason.diskFull.message == "Not enough disk space")
        #expect(FailReason.noTrash.message == "No Trash on this volume")
        #expect(FailReason.exportFolderUnavailable.message == "Export folder unavailable")
        #expect(FailReason.destinationChanged.message == "Destination changed while processing")
        #expect(FailReason.fileChanged.message == "File changed while processing")
        #expect(FailReason.encodeFailed.message == "Couldn't encode this image (codec error)")
        #expect(FailReason.losslessEncoderUnavailable.message == "Couldn’t preserve Lossless JPEG quality. Source unchanged. Retry, or turn off Lossless to allow lossy encoding")
    }

    @Test func notes_haveReadablePresentation() {
        #expect(Note.hdrRemoved.message == "HDR removed")
        #expect(Note.keptFullColor.message == "kept full color")
        #expect(Note.reencodedVisuallyLossless.message == "re-encoded at visually lossless quality")
        #expect(Note.sourceCleanupFailed.message == "Output saved; couldn’t remove the original")
        #expect(Note.copiedUnchanged.message == "copied unchanged")
        #expect(Note.resized(from: 4032, to: 2048).message == "resized \(4032.formatted()) → \(2048.formatted())")
        #expect(Note.resized(from: 4032, to: 2048).spokenMessage == "resized from \(4032.formatted()) to \(2048.formatted()) pixels")
        #expect(Note.resized(from: 4, to: 1).spokenMessage == "resized from 4 to 1 pixel")
        #expect(Note.resized(from: 4, to: 2).spokenMessage == "resized from 4 to 2 pixels")
        #expect(Note.hdrRemoved.spokenMessage == Note.hdrRemoved.message)
    }
}
