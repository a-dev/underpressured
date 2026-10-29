import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

/// Builds a model on a real Queue whose pipeline returns `outcome` for every Item,
/// and an intake that turns each dropped URL into one Waiting Item.
@MainActor
func makeModel(
    outcome: Outcome = .optimized(Savings(originalBytes: 1_000, newBytes: 400), notes: [], output: URL(filePath: "/out")),
    ignored: Int = 0,
    settingsStore: any SettingsStore = InMemorySettingsStore(),
    fileExists: @escaping (URL) -> Bool = { _ in true }
) -> AppModel {
    let queue = Queue(parallelism: 2, pixelBudget: 1_000_000) { _, _, executionContext, _ in outcome }
    return AppModel(
        queue: queue,
        intake: { urls, _, _ in
            ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: ignored)
        },
        settingsStore: settingsStore, fileExists: fileExists)
}

@MainActor
@Suite struct AppModelTests {
    @Test func initialSettingsLoadDoesNotWriteBack() {
        let settingsStore = InMemorySettingsStore()
        let model = makeModel(settingsStore: settingsStore)

        #expect(model.presets.presets.map(\.settings) == Preset.starters.map(\.settings))
        #expect(model.presets.activeID == model.presets.presets.first?.id)
        #expect(model.destination == .initial)
        #expect(settingsStore.saved == nil)
    }

    @Test func intakeFailuresRemainVisibleWithoutBecomingImages() async {
        let url = URL(filePath: "/locked")
        let failure = ScanFailure(url: url, reason: .noPermission)
        let model = AppModel(
            queue: Queue(parallelism: 1, pixelBudget: 100) { _, _, executionContext, _ in
                Issue.record("Unreadable paths must not enter the pipeline")
                return .cancelled
            },
            intake: { _, _, _ in ScanResult(failures: [failure]) },
            settingsStore: InMemorySettingsStore())
        await model.open([url])
        await model.untilIdle()
        await model.open([url])
        await model.untilIdle()
        #expect(model.intakeFailures == [failure])
        #expect(model.rows.isEmpty)
        #expect(model.canClear)
        model.clear()
        #expect(model.intakeFailures.isEmpty)
    }

    @Test func dropRunsToTheBanner() async {
        let model = makeModel(ignored: 3)
        await model.open([URL(filePath: "/tmp/a.jpg"), URL(filePath: "/tmp/b.png")])
        await model.untilIdle()

        #expect(!model.isRunning)
        #expect(model.rows.map(\.name) == ["a.jpg", "b.png"])
        #expect(model.rows.allSatisfy { $0.stateText == "Optimized" && $0.savingsText == Presentation.percent(-60, signed: true) })
        let banner = model.banner?.text ?? ""
        #expect(banner.hasPrefix("2 images · "))
        #expect(banner.hasSuffix(" · 3 other files ignored"))
        #expect(model.canClear)
    }

    @Test func eachDropIsOneSectionWithItsFolderAndPreset() async {
        let model = makeModel()
        await model.open([URL(filePath: "/tmp/a.jpg"), URL(filePath: "/tmp/b.png")])
        await model.untilIdle()
        await model.open([URL(filePath: "/tmp/c.jpg")])
        await model.untilIdle()

        #expect(model.sections.map { $0.rows.map(\.name) } == [["a.jpg", "b.png"], ["c.jpg"]])
        #expect(model.sections.allSatisfy { $0.title == "/tmp" })
        #expect(model.sections.allSatisfy { $0.presetName == model.presets.active.name })
    }
}
