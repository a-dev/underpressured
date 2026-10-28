import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

@Suite struct ItemRowTests {
    private func item(
        _ path: String, root: String? = nil, _ state: ItemState = .waiting
    ) -> Item {
        Item(source: URL(filePath: path), droppedRoot: root.map { URL(filePath: $0) }, state: state)
    }

    private func row(_ outcome: Outcome, path: String = "/tmp/a.jpg") -> ItemRow {
        Presentation.row(for: item(path, .finished(outcome)))
    }

    @Test func looseFileHasNoFolderPath() {
        let r = Presentation.row(for: item("/tmp/a.jpg"))
        #expect(r.name == "a.jpg")
        #expect(r.folderPath == nil)
        #expect(r.stateText == "Waiting")
        #expect(r.issueText == nil)
        #expect(!r.isProcessing)
        #expect(r.sizesText == nil && r.savingsText == nil && r.detail == nil)
    }

    @Test func fileDirectlyInDroppedFolderShowsFolderName() {
        let r = Presentation.row(for: item("/x/Trip/a.jpg", root: "/x/Trip"))
        #expect(r.folderPath == "Trip")
    }

    @Test func nestedFolderPathIsRelativeToTheDroppedFolder() {
        let r = Presentation.row(for: item("/x/Trip/Day 1/Beach/a.jpg", root: "/x/Trip"))
        #expect(r.folderPath == "Trip/Day 1/Beach")
        #expect(r.name == "a.jpg")
    }

    @Test func processingShowsASpinnerState() {
        let r = Presentation.row(for: item("/tmp/a.jpg", .processing(.encoding)))
        #expect(r.stateText == "Processing")
        #expect(r.issueText == nil)
        #expect(r.isProcessing)
    }

    @Test func optimizedShowsSizesAndSavings() {
        let r = row(.optimized(Savings(originalBytes: 4_000_000, newBytes: 1_000_000), notes: [], output: URL(filePath: "/out")))
        #expect(r.stateText == "Optimized")
        #expect(r.issueText == nil)
        #expect(r.sizesText == "\(Presentation.size(4_000_000)) → \(Presentation.size(1_000_000))")
        #expect(r.savingsText == "-75%")
        #expect(!r.isGrowth)
        #expect(r.isReduction)
        #expect(r.detail == nil)
    }

    @Test func negativeSavingsShowAsGrowth() {
        let r = row(.optimized(Savings(originalBytes: 1_000, newBytes: 1_180), notes: [], output: URL(filePath: "/out")))
        #expect(r.savingsText == "+18%")
        #expect(r.isGrowth)
        #expect(!r.isReduction)
    }

    @Test func conversionShowsActualOutputExtension() {
        let r = row(.optimized(Savings(originalBytes: 100, newBytes: 50), notes: [],
                               output: URL(filePath: "/tmp/a.jpg")), path: "/tmp/a.png")
        #expect(r.name == "a.png")
        #expect(r.convertedExtension == ".jpg")
        #expect(r.accessibilityLabel.contains("a.jpg"))
    }

    @Test func unchangedFormatDoesNotShowConversion() {
        let r = row(.optimized(Savings(originalBytes: 100, newBytes: 50), notes: [],
                               output: URL(filePath: "/tmp/a.jpg")), path: "/tmp/a.JPG")
        #expect(r.convertedExtension == nil)
        #expect(row(.skipped(.alreadyOptimal, notes: [])).convertedExtension == nil)
        #expect(row(.failed(.noPermission)).convertedExtension == nil)
        #expect(row(.cancelled).convertedExtension == nil)
    }

    @Test func tinyChangesRoundToZeroWithoutASign() {
        let grew = row(.optimized(Savings(originalBytes: 10_000, newBytes: 10_001), notes: [], output: URL(filePath: "/out")))
        #expect(grew.savingsText == "0%")
        #expect(!grew.isGrowth)
        #expect(!grew.isReduction)
        let saved = row(.optimized(Savings(originalBytes: 10_000, newBytes: 9_999), notes: [], output: URL(filePath: "/out")))
        #expect(saved.savingsText == "0%")
        #expect(!saved.isReduction)
    }

    @Test func notesAreJoinedOnTheSecondaryLine() {
        let r = row(.optimized(
            Savings(originalBytes: 100, newBytes: 50),
            notes: [.resized(from: 4032, to: 2048), .hdrRemoved], output: URL(filePath: "/out")))
        #expect(r.detail == "resized \(4032.formatted()) → \(2048.formatted()) · HDR removed")
    }

    @Test func skippedShowsReasonAndNotesWithoutSizes() {
        let r = row(.skipped(.alreadyOptimal, notes: [.copiedUnchanged]))
        #expect(r.stateText == "Skipped")
        #expect(r.issueText == "Skipped")
        #expect(r.detail == "Already optimal · copied unchanged")
        #expect(r.sizesText == nil && r.savingsText == nil)
        #expect(row(.skipped(.alreadyInQueue, notes: [])).detail == "Already in the queue")
    }

    @Test func failedShowsReason() {
        let r = row(.failed(.noPermission))
        #expect(r.stateText == "Failed")
        #expect(r.issueText == "Failed")
        #expect(r.detail == "No permission to access this file or folder")
    }

    @Test func cancelledHasNoDetail() {
        let r = row(.cancelled)
        #expect(r.stateText == "Cancelled")
        #expect(r.issueText == "Cancelled")
        #expect(r.detail == nil)
    }
}
