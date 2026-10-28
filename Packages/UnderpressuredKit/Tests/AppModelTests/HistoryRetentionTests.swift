import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HistoryRetentionTests {
    @Test func historySurvivesExecutionRetirementAndClearResetsSummary() async {
        let queue = Queue(parallelism: 4) { _, _, executionContext, _ in .failed(.cantRead) }
        let model = AppModel(queue: queue, intake: { urls, _, _ in
            ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: 3)
        }, updateInterval: .zero)
        for cycle in 0..<20 {
            let first = URL(filePath: "/tmp/first-\(cycle).jpg")
            let second = URL(filePath: "/tmp/second-\(cycle).jpg")
            await model.open([first])
            await model.untilIdle()
            #expect(await queue.snapshot.isEmpty)
            #expect(model.rows.map(\.name) == [first.lastPathComponent])
            await model.open([second])
            await model.untilIdle()
            #expect(model.rows.map(\.name) == [first.lastPathComponent, second.lastPathComponent])
            #expect(model.sections.count == 2)
            #expect(model.runSummary?.images == 1)
            #expect(model.runSummary?.ignored == 3)
            #expect(model.remainingCount == 0)
            model.selection = Set(model.rows.map(\.id))
            model.filter = .failed
            model.clear()
            #expect(model.isEmpty && model.rows.isEmpty && model.sections.isEmpty)
            #expect(model.selection.isEmpty && model.filter == nil)
            #expect(model.runSummary == nil && model.banner == nil)
            #expect(model.footer.savingsText == nil && model.remainingCount == 0)
            let retained = await queue.diagnostics
            #expect(retained.items == 0 && retained.batches == 0 && retained.waitingSlots == 0)
        }
    }
}
