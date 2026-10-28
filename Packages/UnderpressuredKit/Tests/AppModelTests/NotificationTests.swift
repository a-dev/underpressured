import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

/// Records what the model asks of the notifier instead of posting anything.
@MainActor
final class RecordingNotifier: Notifier {
    private(set) var permissionRequests = 0
    private(set) var posts: [String] = []

    func requestPermission() { permissionRequests += 1 }
    func post(_ text: String) { posts.append(text) }
}

/// Same shape as `makeModel` in AppModelTests.swift: every Item finishes with one optimized Outcome.
@MainActor
func makeNotifyingModel(notifier: RecordingNotifier, isFrontmost: @escaping @MainActor () -> Bool) -> AppModel {
    let outcome = Outcome.optimized(Savings(originalBytes: 1_000, newBytes: 400), notes: [], output: URL(filePath: "/out"))
    let queue = Queue(parallelism: 2, pixelBudget: 1_000_000) { _, _, executionContext, _ in outcome }
    return AppModel(
        queue: queue,
        intake: { urls, _, _ in
            ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: 0)
        },
        notifier: notifier,
        isFrontmost: isFrontmost)
}

@MainActor
@Suite struct NotificationTests {
    @Test func permissionIsRequestedOnceForTheFirstBatch() async {
        let notifier = RecordingNotifier()
        let model = makeNotifyingModel(notifier: notifier, isFrontmost: { true })
        await model.open([URL(filePath: "/tmp/a.jpg")])
        await model.open([URL(filePath: "/tmp/b.png")])
        await model.untilIdle()

        #expect(notifier.permissionRequests == 1)
    }

    @Test func postsTheBannerTextWhenNotFrontmost() async {
        let notifier = RecordingNotifier()
        let model = makeNotifyingModel(notifier: notifier, isFrontmost: { false })
        await model.open([URL(filePath: "/tmp/a.jpg"), URL(filePath: "/tmp/b.png")])
        await model.untilIdle()

        let banner = model.banner?.text ?? ""
        #expect(!banner.isEmpty)
        #expect(notifier.posts == [banner])
    }

    @Test func doesNotPostWhenFrontmost() async {
        let notifier = RecordingNotifier()
        let model = makeNotifyingModel(notifier: notifier, isFrontmost: { true })
        await model.open([URL(filePath: "/tmp/a.jpg"), URL(filePath: "/tmp/b.png")])
        await model.untilIdle()

        #expect(model.banner != nil)
        #expect(notifier.posts.isEmpty)
    }
}
