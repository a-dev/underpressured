import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

/// Selection and what Open and Quick Look may show (plan-finder-list 1.2).
@MainActor
@Suite struct SelectionTests {
    private let a = URL(filePath: "/tmp/a.jpg")
    private let b = URL(filePath: "/tmp/b.jpg")
    private let c = URL(filePath: "/tmp/c.jpg")

    /// Each source gets its own outcome; the output of an Optimized one is "<name>.out".
    private func model(
        _ outcomes: [String: Outcome], fileExists: @escaping (URL) -> Bool = { _ in true }
    ) async -> AppModel {
        let queue = Queue(parallelism: 2, pixelBudget: 1_000_000) { item, _, executionContext, _ in
            outcomes[item.source.lastPathComponent] ?? .cancelled
        }
        let model = AppModel(
            queue: queue,
            intake: { urls, _, _ in ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: 0) },
            fileExists: fileExists)
        await model.open([a, b, c])
        await model.untilIdle()
        return model
    }

    private func optimized(_ output: String) -> Outcome {
        .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: URL(filePath: output))
    }

    @Test func optimizedOpensItsOutput() async {
        let model = await model(["a.jpg": optimized("/Export/a-2.jpg")])
        #expect(model.openableURLs(for: Set(model.rows.map(\.id))) == [URL(filePath: "/Export/a-2.jpg")])
    }

    @Test func skippedOpensTheCopyOrTheSource() async {
        let model = await model([
            "a.jpg": .skipped(.alreadyOptimal, notes: [.copiedUnchanged], output: URL(filePath: "/Export/a.jpg")),
            "b.jpg": .skipped(.alreadyOptimal, notes: []),
        ])
        #expect(model.openableURLs(for: Set(model.rows.map(\.id))) == [URL(filePath: "/Export/a.jpg"), b])
    }

    @Test func failedAndCancelledAreNotOpenable() async {
        let model = await model(["a.jpg": .failed(.cantRead)])
        #expect(model.rows.map(\.openURL) == [nil, nil, nil])
        #expect(model.openableURLs(for: Set(model.rows.map(\.id))).isEmpty)
    }

    @Test func waitingAndProcessingAreNotOpenable() {
        #expect(Presentation.row(for: Item(source: a, droppedRoot: nil)).openURL == nil)
        #expect(Presentation.row(for: Item(source: a, droppedRoot: nil, state: .processing(.encoding))).openURL == nil)
    }

    @Test func deletedOutputIsDropped() async {
        let model = await model(
            ["a.jpg": optimized("/out/a.jpg"), "b.jpg": optimized("/out/b.jpg")],
            fileExists: { $0.path != "/out/a.jpg" })
        #expect(model.openableURLs(for: Set(model.rows.map(\.id))) == [URL(filePath: "/out/b.jpg")])
    }

    @Test func keepsListOrderWhateverTheSelectionOrder() async {
        let model = await model(["a.jpg": optimized("/out/a"), "b.jpg": optimized("/out/b"), "c.jpg": optimized("/out/c")])
        let ids = model.rows.map(\.id)
        #expect(model.openableURLs(for: [ids[2], ids[0]]) == [URL(filePath: "/out/a"), URL(filePath: "/out/c")])
    }

    @Test func clearEmptiesTheSelection() async {
        let model = await model(["a.jpg": optimized("/out/a")])
        model.selection = Set(model.rows.map(\.id))
        model.clear()
        #expect(model.selection.isEmpty)
    }

    @Test func filteringClearsHiddenSelectionAndItsPreviewURLs() async {
        let model = await model(["a.jpg": optimized("/out/a"), "b.jpg": .failed(.cantRead)])
        let selected = model.rows[0].id
        model.selection = [selected]
        let revision = model.intakeAdmissionRevision
        model.toggleFilter(.failed)
        #expect(model.selection.isEmpty)
        #expect(model.openableURLs(for: model.selection).isEmpty)
        #expect(model.intakeAdmissionRevision == revision)
        model.toggleFilter(.failed)
        #expect(model.selection.isEmpty)
        #expect(model.intakeAdmissionRevision == revision)
    }

    @Test func filterRetainsSelectedVisibleRows() async {
        let model = await model(["a.jpg": optimized("/out/a"), "b.jpg": .failed(.cantRead)])
        let failed = model.rows[1].id
        model.selection = Set(model.rows.map(\.id))
        model.toggleFilter(.failed)
        #expect(model.selection == [failed])
    }

    @Test func admissionSignalAdvancesOnlyForNonemptyBatches() async {
        let model = await model(["a.jpg": optimized("/out/a")])
        let revision = model.intakeAdmissionRevision
        await model.open([a])
        await model.untilIdle()
        #expect(model.intakeAdmissionRevision == revision + 1)
        let empty = AppModel(queue: Queue(parallelism: 1, pixelBudget: 1_000) { _, _, executionContext, _ in .cancelled },
                             intake: { _, _, _ in ScanResult(items: [], ignoredCount: 1) })
        await empty.open([a])
        await empty.untilIdle()
        #expect(empty.intakeAdmissionRevision == 0)
    }
}
