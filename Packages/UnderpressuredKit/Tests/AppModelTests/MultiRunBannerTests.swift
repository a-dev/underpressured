import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MultiRunBannerTests {
    @Test func bannerFiltersCoverEveryRunInTheList() async {
        let queue = Queue(parallelism: 2) { item, _, executionContext, _ in
            item.source.lastPathComponent.hasPrefix("bad") ? .failed(.cantRead) : .skipped(.alreadyOptimized, notes: [], output: nil)
        }
        let notifier = RecordingNotifier()
        let model = AppModel(queue: queue, intake: { urls, _, _ in
            ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: 1)
        }, notifier: notifier, isFrontmost: { false }, updateInterval: .zero)
        await model.open([URL(filePath: "/tmp/bad.jpg")])
        await model.untilIdle()
        await model.open([URL(filePath: "/tmp/fine.jpg")])
        await model.untilIdle()

        #expect(model.banner?.filters.map(\.filter) == [.failed, .skipped])
        model.toggleFilter(.failed)
        #expect(model.rows.map(\.name) == ["bad.jpg"])
        #expect(model.runSummary?.images == 1)
        #expect(notifier.posts.last?.contains("failed") == false)
    }
}
