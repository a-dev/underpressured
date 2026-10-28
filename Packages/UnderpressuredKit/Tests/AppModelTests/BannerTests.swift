import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

@MainActor
@Suite struct BannerTests {
    private func summary(
        images: Int = 0, optimized: Int = 0, failed: Int = 0, skipped: Int = 0, cancelled: Int = 0,
        ignored: Int = 0, original: Int64 = 0, new: Int64 = 0
    ) -> RunSummary {
        var s = RunSummary()
        s.images = images
        s.finished = images
        s.optimized = optimized
        s.failed = failed
        s.skipped = skipped
        s.cancelled = cancelled
        s.ignored = ignored
        s.originalBytes = original
        s.newBytes = new
        return s
    }

    @Test func specExample() {
        let s = summary(images: 128, optimized: 126, failed: 2, ignored: 14, original: 100_000_000, new: 38_000_000)
        let banner = Presentation.banner(s, filter: nil)
        let saved = Presentation.size(62_000_000)
        #expect(banner.text == "128 images · \(saved) saved (62%) · 2 failed · 14 other files ignored")
        #expect(banner.filters.map(\.title) == ["2 failed"])
    }

    @Test func singularForms() {
        let s = summary(images: 1, failed: 1, ignored: 1)
        let banner = Presentation.banner(s, filter: nil)
        #expect(banner.text == "1 image · nothing optimized · 1 failed · 1 other file ignored")
    }

    @Test func buttonsForEachNonzeroCountInOrder() {
        let s = summary(images: 6, optimized: 1, failed: 1, skipped: 2, cancelled: 2, original: 10, new: 5)
        let banner = Presentation.banner(s, filter: .skipped)
        #expect(banner.filters.map(\.filter) == [.failed, .skipped, .cancelled])
        #expect(banner.filters.map(\.isOn) == [false, true, false])
        #expect(banner.text.hasSuffix(" · 1 failed · 2 skipped · 2 cancelled"))
    }

    @Test func growthReadsAsLarger() {
        let s = summary(images: 1, optimized: 1, original: 1_000_000, new: 1_180_000)
        let text = Presentation.banner(s, filter: nil).text
        #expect(text == "1 image · \(Presentation.size(180_000)) larger (18%)")
    }

    @Test func footerRunningAndIdle() {
        var s = summary(images: 128, optimized: 37, original: 1_000_000, new: 500_000)
        s.finished = 37
        let running = Presentation.footer(s, isRunning: true)
        #expect(running.progressText == "37 / 128")
        #expect(running.savingsText == "\(Presentation.size(500_000)) saved (50%)")
        let idle = Presentation.footer(s, isRunning: false)
        #expect(idle.progressText == nil)
        #expect(idle.savingsText == running.savingsText)
        #expect(Presentation.footer(nil, isRunning: false).savingsText == nil)
    }

    @Test func modelFiltersRowsAndToggles() async {
        let model = makeModel(outcome: .failed(.cantRead))
        await model.open([URL(filePath: "/tmp/a.jpg"), URL(filePath: "/tmp/b.png")])
        await model.untilIdle()

        #expect(model.banner?.text == "2 images · nothing optimized · 2 failed")
        #expect(model.banner?.filters.map { $0.title } == ["2 failed"])
        model.toggleFilter(.failed)
        #expect(model.banner?.filters.first?.isOn == true)
        #expect(model.rows.count == 2)
        model.toggleFilter(.skipped)
        #expect(model.rows.isEmpty)
        model.toggleFilter(.skipped)
        #expect(model.filter == nil)
        #expect(model.rows.count == 2)
        #expect(model.footer.progressText == nil)
        #expect(model.footer.savingsText == nil)
    }
}
