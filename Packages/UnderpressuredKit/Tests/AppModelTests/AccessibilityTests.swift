import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

@Suite struct AccessibilityTests {
    private func row(_ path: String, root: String? = nil, _ state: ItemState) -> ItemRow {
        Presentation.row(for: Item(
            source: URL(filePath: path), droppedRoot: root.map { URL(filePath: $0) }, state: state))
    }

    @Test func badgeLabelsAndValue() {
        #expect(AccessibilityText.presetBadge(name: "Web") == "Web preset")
        #expect(AccessibilityText.presetBadgeValue(isActive: true) == "active")
        #expect(AccessibilityText.presetBadgeValue(isActive: false) == nil)
        #expect(AccessibilityText.presetBadgeSpoken(name: "Web", isActive: true) == "Web preset, active")
        #expect(AccessibilityText.presetBadgeSpoken(name: "Web", isActive: false) == "Web preset")
    }

    @Test func buttonLabels() {
        #expect(AccessibilityText.editPreset(name: "Web") == "Edit Web preset")
        #expect(AccessibilityText.addPreset == "Add preset")
    }

    @Test func fixedStrings() {
        #expect(AccessibilityText.destinationMenu(title: "→ Photos") == "Destination: → Photos")
        #expect(AccessibilityText.resizePixels == "Resize Rule pixels")
        #expect(AccessibilityText.emptyStateHint.contains("Command O"))
        #expect(AccessibilityText.clearList.hasPrefix("Clear"))
        #expect(AccessibilityText.openAction == "Open")
        #expect(AccessibilityText.quickLookAction == "Quick Look")
    }

    @Test func optimizedRowReadsInFull() {
        let r = row("/x/Trip/Day 1/photo.jpg", root: "/x/Trip",
                    .finished(.optimized(Savings(originalBytes: 4_000_000, newBytes: 1_000_000), notes: [], output: URL(filePath: "/out"))))
        let size = Presentation.size
        #expect(r.accessibilityLabel
            == "photo.jpg in Trip/Day 1, Optimized, \(size(4_000_000)) to \(size(1_000_000)), 75 percent smaller")
    }

    @Test func growthAndZeroAreSpoken() {
        let grew = row("/tmp/a.jpg", .finished(.optimized(Savings(originalBytes: 1_000, newBytes: 1_180), notes: [], output: URL(filePath: "/out"))))
        #expect(grew.accessibilityLabel.hasSuffix("18 percent larger"))
        let same = row("/tmp/a.jpg", .finished(.optimized(Savings(originalBytes: 10_000, newBytes: 10_001), notes: [], output: URL(filePath: "/out"))))
        #expect(same.accessibilityLabel.hasSuffix("no size change"))
    }

    @Test func looseWaitingRowAndDetail() {
        #expect(row("/tmp/a.jpg", .waiting).accessibilityLabel == "a.jpg, Waiting")
        let failed = row("/tmp/a.jpg", .finished(.cancelled))
        #expect(failed.accessibilityLabel == "a.jpg, Cancelled")
        let detailed = row("/tmp/a.jpg", .finished(.skipped(.alreadyOptimal, notes: [.copiedUnchanged])))
        #expect(detailed.accessibilityLabel == "a.jpg, Skipped, Already optimal, copied unchanged")
    }

    @Test func footerAndBannerAreSpoken() {
        var summary = RunSummary()
        summary.images = 128
        summary.finished = 37
        summary.optimized = 37
        summary.failed = 2
        summary.originalBytes = 100_000_000
        summary.newBytes = 38_000_000
        let footer = Presentation.footer(summary, isRunning: true)
        let saved = Presentation.size(62_000_000)
        #expect(footer.accessibilityLabel == "37 of 128 finished, \(saved) saved, 62 percent")
        #expect(Presentation.footer(nil, isRunning: false).accessibilityLabel == nil)
        #expect(Presentation.banner(summary, filter: nil).accessibilityLabel == "128 images, \(saved) saved, 62 percent, 2 failed")
    }

    @Test func speechUsesStructuredValuesAndPreservesUserText() {
        let r = row("/tmp/写真 99% → test.jpg", .finished(.optimized(
            Savings(originalBytes: 1000, newBytes: 500), notes: [.resized(from: 2048, to: 1024)], output: URL(filePath: "/out"))))
        #expect(r.accessibilityLabel.hasPrefix("写真 99% → test.jpg, Optimized"))
        #expect(r.accessibilityLabel.hasSuffix("resized from \(2048.formatted()) to \(1024.formatted()) pixels"))
        #expect(r.accessibilityLabel.contains("50 percent smaller"))
    }

    @Test func filterButton() {
        #expect(AccessibilityText.filterButton(title: "2 failed") == "Show only 2 failed")
        #expect(AccessibilityText.filterButtonValue(isOn: true) == "showing")
        #expect(AccessibilityText.filterButtonValue(isOn: false) == nil)
    }
}
