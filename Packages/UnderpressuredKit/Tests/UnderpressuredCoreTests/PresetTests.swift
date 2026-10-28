import Foundation
import Testing
@testable import UnderpressuredCore

@Suite struct PresetTests {
    private func sample() -> Preset {
        Preset(name: "Web", quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)
    }

    // MARK: §4.1 Name

    @Test func name_spec4_1_maxNameLengthIsSeventy() {
        #expect(Preset.maxNameLength == 70)
    }

    @Test func name_spec4_1_literal69_70_71ComposedCharacters() {
        var preset = sample()
        let composedCharacter = "e\u{301}"
        let boundaryNames = [
            (input: String(repeating: composedCharacter, count: 69), expected: String(repeating: composedCharacter, count: 69)),
            (input: String(repeating: composedCharacter, count: 70), expected: String(repeating: composedCharacter, count: 70)),
            (input: String(repeating: composedCharacter, count: 71), expected: String(repeating: composedCharacter, count: 70))
        ]

        for boundary in boundaryNames {
            preset.setName(boundary.input)
            #expect(preset.name == boundary.expected)
        }

        preset.setName("  \(String(repeating: "👍🏽", count: 70))  ")
        #expect(preset.name == String(repeating: "👍🏽", count: 70))
        preset.setName("  \(String(repeating: "👍🏽", count: 71))  ")
        #expect(preset.name == String(repeating: "👍🏽", count: 70))
    }

    @Test func name_spec4_1_oneToSeventyCharactersKept() {
        var preset = sample()
        preset.setName("A")
        #expect(preset.name == "A")
        preset.setName(String(repeating: "A", count: 70))
        #expect(preset.name == String(repeating: "A", count: 70))
    }

    @Test func name_spec4_1_longerThanSeventyIsTruncated() {
        var preset = sample()
        preset.setName(String(repeating: "A", count: 71))
        #expect(preset.name == String(repeating: "A", count: 70))
    }

    @Test func name_spec4_1_countsCharactersNotBytes() {
        var preset = sample()
        preset.setName(String(repeating: "👍🏽", count: 71))
        #expect(preset.name.count == 70)
    }

    @Test func name_spec4_1_twoPresetsMayShareAName() {
        var a = sample()
        var b = sample()
        a.setName("Same")
        b.setName("Same")
        #expect(a.name == b.name && a.id != b.id)
    }

    @Test func name_spec4_3_emptyNameKeepsPrevious() {
        var preset = sample()
        preset.setName("")
        #expect(preset.name == "Web")
    }

    @Test func name_spec10_4_whitespaceOnlyCountsAsEmpty() {
        var preset = sample()
        preset.setName("  \n ")
        #expect(preset.name == "Web")
    }

    @Test func name_spec4_1_surroundingWhitespaceTrimmed() {
        var preset = sample()
        preset.setName("  Mail  ")
        #expect(preset.name == "Mail")
    }

    // MARK: §4.1 Quality, Lossless, Keep metadata

    @Test func quality_spec4_1_clampedToZeroThroughHundred() {
        var preset = sample()
        preset.setQuality(-5)
        #expect(preset.quality == 0)
        preset.setQuality(0)
        #expect(preset.quality == 0)
        preset.setQuality(100)
        #expect(preset.quality == 100)
        preset.setQuality(101)
        #expect(preset.quality == 100)
    }

    @Test func losslessAndKeepMetadata_spec4_1_areIndependentOfQuality() {
        var preset = sample()
        preset.lossless = true
        preset.keepMetadata = true
        #expect(preset.quality == 80 && preset.lossless && preset.keepMetadata)
    }

    // MARK: §4.1 Resize Rule

    @Test func resizeRule_spec4_1_allFourKinds() {
        #expect(ResizeRule.none.isValid)
        #expect(ResizeRule.maxWidth(1).isValid)
        #expect(ResizeRule.maxHeight(1).isValid)
        #expect(ResizeRule.maxLongEdge(2048).isValid)
    }

    @Test func resizeRule_spec4_1_pixelValueMustBePositive() {
        for rule in [ResizeRule.maxWidth(0), .maxHeight(-3), .maxLongEdge(0)] {
            #expect(rule.isValid)
            #expect(rule.pixels == 1)
        }
        var preset = sample()
        preset.setResizeRule(.maxLongEdge(-10))
        #expect(preset.resizeRule == .maxLongEdge(1))
        preset.setResizeRule(.maxWidth(640))
        #expect(preset.resizeRule == .maxWidth(640))
    }

    // MARK: §4.2 Starter Presets

    @Test func starters_spec4_2_balanced() {
        let p = Preset.starters[0]
        #expect(p.name == "Balanced JPEG" && p.quality == 80 && !p.lossless)
        #expect(p.resizeRule == .none && !p.keepMetadata && p.outputFormat == .jpeg)
    }

    @Test func starters_spec4_2_web() {
        let p = Preset.starters[1]
        #expect(p.name == "Web" && p.quality == 80 && !p.lossless)
        #expect(p.resizeRule == .maxLongEdge(2048) && !p.keepMetadata)
    }

    @Test func starters_spec4_2_screenshots() {
        let p = Preset.starters[3]
        #expect(p.name == "Screenshots PNG" && p.quality == 70 && !p.lossless)
        #expect(p.resizeRule == .none && p.keepMetadata && p.outputFormat == .png)
    }

    @Test func starters_spec4_2_small() {
        let p = Preset.starters[2]
        #expect(p.name == "Small" && p.quality == 60 && !p.lossless)
        #expect(p.resizeRule == .maxLongEdge(1080) && !p.keepMetadata && p.outputFormat == .original)
    }

    @Test func starters_spec4_2_fourValidPresetsWithDistinctIDs() {
        let starters = Preset.starters
        #expect(starters.count == 4)
        let allValid = starters.allSatisfy { $0.isValid }
        #expect(allValid)
        #expect(Set(starters.map(\.id)).count == 4)
        #expect(starters.map(\.starterID) == [.balanced, .web, .small, .screenshots])
    }

    @Test func customNamesMatchingStarterLabelsDoNotReceiveStarterIdentity() {
        for name in ["Balanced", "Balanced JPEG", "Web", "Small", "Screenshots PNG"] {
            let preset = Preset(name: name, quality: 5, lossless: true, resizeRule: .none, keepMetadata: true)
            #expect(preset.starterID == nil)
        }
    }

}
