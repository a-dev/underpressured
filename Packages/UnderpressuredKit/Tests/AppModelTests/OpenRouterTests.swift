import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

@MainActor
private func makeRouterModel() -> AppModel {
    let queue = Queue(parallelism: 2, pixelBudget: 1_000_000) { _, _, executionContext, _ in
        .optimized(Savings(originalBytes: 1_000, newBytes: 400), notes: [], output: URL(filePath: "/out"))
    }
    return AppModel(
        queue: queue,
        intake: { urls, _, _ in ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: 0) })
}

@MainActor
@Suite struct OpenRouterTests {
    private let a = URL(filePath: "/tmp/a.jpg")
    private let b = URL(filePath: "/tmp/b.png")
    private let c = URL(filePath: "/tmp/c.heic")

    @Test func windowDropAndRouterReachTheSameMethod() async {
        let dropped = makeRouterModel()
        await dropped.open([a, b])
        await dropped.untilIdle()

        let routed = makeRouterModel()
        let router = OpenRouter()
        await router.attach(routed)
        await router.open([a, b])
        await routed.untilIdle()

        #expect(routed.rows.map(\.name) == dropped.rows.map(\.name))
        #expect(routed.rows.map(\.stateText) == dropped.rows.map(\.stateText))
    }

    @Test func urlsBeforeAttachAreKeptAndFlushedInOrder() async {
        let model = makeRouterModel()
        let router = OpenRouter()
        await router.open([a])
        await router.open([b, c])
        #expect(model.isEmpty)

        await router.attach(model)
        await model.untilIdle()
        #expect(model.rows.map(\.name) == ["a.jpg", "b.png", "c.heic"])
    }

    @Test func urlsAfterAttachAreOpenedAndNothingIsReplayed() async {
        let model = makeRouterModel()
        let router = OpenRouter()
        await router.attach(model)
        await router.open([a])
        await router.open([b])
        await model.untilIdle()
        #expect(model.rows.map(\.name) == ["a.jpg", "b.png"])

        await router.attach(model)
        await model.untilIdle()
        #expect(model.rows.count == 2)
    }
}
