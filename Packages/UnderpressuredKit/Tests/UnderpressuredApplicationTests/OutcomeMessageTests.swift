import Testing

@testable import UnderpressuredCore
@testable import UnderpressuredApplication

struct OutcomeMessageTests {
    @Test func diagnosticIDs_areStableAndEnglishOnly() {
        #expect(SkipReason.alreadyOptimal.diagnosticID == "already_optimal")
        #expect(SkipReason.cantWriteYet(.jpegXL).diagnosticID == "cant_write_yet.jpeg_xl")
        #expect(SkipReason.unsupported(.multiPageTIFF).diagnosticID == "unsupported.multi_page_tiff")
        #expect(FailReason.diskFull.diagnosticID == "disk_full")
        #expect(FailReason.losslessEncoderUnavailable.diagnosticID == "lossless_encoder_unavailable")
    }

    @Test func fileErrorsMapToFailReasons_spec7_8() {
        #expect(FileAccessError.notFound.failReason.diagnosticID == "file_not_found")
        #expect(FileAccessError.alreadyExists.failReason.diagnosticID == "file_already_exists")
        #expect(FileAccessError.other("private detail").failReason.diagnosticID == "file_io_failed")
        #expect(FileAccessError.permissionDenied.failReason == .noPermission)
        #expect(FileAccessError.diskFull.failReason == .diskFull)
        #expect(FileAccessError.noTrash.failReason == .noTrash)
    }

    @Test func onlyOptimalAndOptimizedAreCopiedToExport_spec6_2() {
        #expect(SkipReason.alreadyOptimal.copiesToExportFolder)
        #expect(SkipReason.alreadyOptimized.copiesToExportFolder)
        #expect(!SkipReason.alreadyInQueue.copiesToExportFolder)
        #expect(!SkipReason.unsupported(.gif).copiesToExportFolder)
    }
}

struct PresetFieldTests {
    @Test func presetHoldsOutputFormatButNoDestination_spec4_1() {
        let preset = Preset(name: "Web", quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)
        let labels = Mirror(reflecting: preset).children.compactMap(\.label)
        #expect(Set(labels) == ["id", "name", "quality", "lossless", "resizeRule", "keepMetadata", "outputFormat", "starterID"])
    }
}
