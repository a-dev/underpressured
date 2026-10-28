import Foundation
import Testing
import UnderpressuredCore

struct ValidatedValuesTests {
    @Test(arguments: [-1, 0, 100, 101])
    func qualityClampsValues(_ raw: Int) {
        let expected = min(max(raw, 0), 100)
        let value = Quality.clamping(raw)
        #expect(value.rawValue == expected)
        #expect(value == Quality.clamping(expected))
        let settings = EffectiveSettings(quality: value, lossless: false, resizeRule: .none, keepMetadata: false)
        #expect(settings.quality == value)
    }

    @Test(arguments: [-1, 0, 1, 2048])
    func resizeClampsValues(_ raw: Int) {
        let limit = PixelLimit.clamping(raw)
        #expect(limit.rawValue == max(raw, 1))
        for rule in [ResizeRule.maxWidth(limit), .maxHeight(limit), .maxLongEdge(limit)] {
            #expect(rule.pixels == max(raw, 1))
        }
    }

    @Test(arguments: ["", "   \n", String(repeating: "👨‍👩‍👧‍👦", count: 70), String(repeating: "e\u{301}", count: 71)])
    func presetConstructionAlwaysNormalizesNames(_ name: String) throws {
        var preset = Preset(name: name, quality: .clamping(101), lossless: false, resizeRule: .maxWidth(.clamping(0)), keepMetadata: false)
        #expect(preset.name == (Preset.normalizedName(name) ?? Preset.fallbackName))
        #expect(preset.name.count <= 70 && !preset.name.isEmpty)
        let before = preset
        preset.setName("  ")
        #expect(preset == before)
        let duplicate = preset.duplicated(name: name)
        #expect(duplicate.id != preset.id && duplicate.starterID == nil)
        #expect(duplicate.settings == preset.settings)
    }

    @Test func namedMutationsIgnoreUnknownIDsAndPreserveIdentity() {
        var list = PresetList.starter
        let before = list
        let unknown = UUID()
        list.rename(unknown, to: "Other")
        list.setQuality(unknown, to: -1)
        list.setResizeRule(unknown, to: .maxWidth(1))
        list.setLossless(unknown, to: true)
        list.setKeepMetadata(unknown, to: true)
        list.setOutputFormat(unknown, to: .png)
        list.restoreName(unknown, from: before.active)
        #expect(list == before)
        let id = list.activeID
        list.setQuality(id, to: 101)
        list.setResizeRule(id, to: .maxHeight(.clamping(-2)))
        list.rename(id, to: "  Renamed  ")
        #expect(list.active.id == id && list.active.name == "Renamed")
        #expect(list.active.quality.rawValue == 100 && list.active.resizeRule.pixels == 1)
        #expect(list.active.starterID == nil)
    }
}
