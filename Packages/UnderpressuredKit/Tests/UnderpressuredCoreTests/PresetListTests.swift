import Foundation
import Testing

@testable import UnderpressuredCore

struct PresetListTests {
    /// A fixed three-Preset list so these tests exercise list rules, not the current starter content.
    private static let fixture = [
        Preset(name: "Balanced", quality: 80, lossless: false, resizeRule: .none, keepMetadata: false),
        Preset(name: "Web", quality: 80, lossless: false, resizeRule: .maxLongEdge(2048), keepMetadata: false),
        Preset(name: "Small", quality: 65, lossless: false, resizeRule: .maxLongEdge(1280), keepMetadata: false)
    ]

    private func list() -> PresetList { PresetList(presets: Self.fixture, activeID: Self.fixture[0].id) }
    private var names: (PresetList) -> [String] { { $0.presets.map(\.name) } }

    @Test func presetList_spec4_3_exactlyOneActive_startsWithBalanced() {
        let list = list()
        #expect(list.active.name == "Balanced")
        #expect(list.presets.filter { $0.id == list.activeID }.count == 1)
    }

    @Test func presetList_spec4_3_clickingBadgeActivates() {
        var list = list()
        let web = list.presets[1]
        list.activate(web.id)
        #expect(list.active == web)
        list.activate(UUID())
        #expect(list.active == web)
    }

    @Test func presetList_spec4_3_activateByPosition_isOneBased_outOfRangeIgnored() {
        var list = list()
        list.activate(position: 3)
        #expect(list.active.name == "Small")
        list.activate(position: 1)
        #expect(list.active.name == "Balanced")
        list.activate(position: Int.min)
        list.activate(position: Int.max)
        list.activate(position: 0)
        list.activate(position: 4)
        list.activate(position: 9)
        #expect(list.active.name == "Balanced")
    }

    @Test func presetList_spec4_3_plusDuplicates_insertsAfterOriginal_andActivates() {
        var list = list()
        list.activate(position: 2)
        let original = list.active
        let copy = list.duplicateActive()
        #expect(names(list) == ["Balanced", "Web", "Web 2", "Small"])
        #expect(list.active == copy)
        #expect(copy.id != original.id)
        #expect(copy.settings == original.settings)
    }

    @Test func presetList_spec4_3_duplicateNumbersSkipExistingNames() {
        var list = list()
        list.activate(position: 2)
        list.duplicateActive()  // Web 2, active
        list.activate(position: 2)  // Web
        list.duplicateActive()  // Web 3
        #expect(names(list) == ["Balanced", "Web", "Web 3", "Web 2", "Small"])
    }

    @Test func presetList_spec4_3_duplicateOfNumberedCopy_isNextNumber() {
        var list = list()
        list.activate(position: 2)
        list.duplicateActive()
        let third = list.duplicateActive()
        #expect(third.name == "Web 3")
    }

    @Test func presetList_spec4_3_duplicateNameRespectsSeventyCharacters() {
        var list = PresetList(
            presets: [Preset(name: String(repeating: "A", count: 70), quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)],
            activeID: UUID())
        let copy = list.duplicateActive()
        #expect(copy.name == String(repeating: "A", count: 68) + " 2")
        #expect(copy.name.count <= Preset.maxNameLength)
        #expect(list.duplicateActive().name == String(repeating: "A", count: 68) + " 3")
    }

    @Test func presetList_spec4_3_duplicateGraphemeNameRespectsLiteralSeventyCharacterLimit() {
        let grapheme = "👍🏽"
        var list = PresetList(
            presets: [Preset(name: String(repeating: grapheme, count: 70), quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)],
            activeID: UUID())
        let copy = list.duplicateActive()

        #expect(copy.name == String(repeating: grapheme, count: 68) + " 2")
        #expect(copy.name.count == 70)
        #expect(list.duplicateActive().name == String(repeating: grapheme, count: 68) + " 3")
    }

    @Test func presetList_spec4_3_duplicateNumbersStaySingleDigitAndWrap() {
        var list = PresetList(
            presets: [Preset(name: String(repeating: "A", count: 70), quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)],
            activeID: UUID())
        let copies = (2...11).map { _ in list.duplicateActive().name }
        #expect(copies.prefix(8) == ArraySlice((2...9).map { String(repeating: "A", count: 68) + " \($0)" }))
        #expect(copies[8] == String(repeating: "A", count: 68) + " 2")
        #expect(copies[9] == String(repeating: "A", count: 68) + " 3")
        #expect(copies.allSatisfy { $0.count <= Preset.maxNameLength })
    }

    @Test func presetList_spec4_3_duplicateFromContextMenu_copiesThatBadge() {
        var list = list()
        let small = list.presets[2]
        let copy = list.duplicate(small.id)
        #expect(names(list) == ["Balanced", "Web", "Small", "Small 2"])
        #expect(list.active == copy)
        #expect(list.duplicate(UUID()) == nil)
    }

    @Test func presetList_spec4_3_lastPresetCannotBeDeleted() {
        var list = PresetList(presets: [Preset.starters[0]], activeID: UUID())
        let deleted = list.delete(list.active.id)
        #expect(!deleted)
        #expect(list.presets.count == 1)
    }

    @Test func presetList_spec4_3_deleteInactive_keepsActive() {
        var list = list()
        let active = list.active
        let deleted = list.delete(list.presets[2].id)
        #expect(deleted)
        #expect(names(list) == ["Balanced", "Web"])
        #expect(list.active == active)
    }

    @Test func presetList_spec4_3_deleteActive_activatesNextNeighbour() {
        var list = list()
        list.activate(position: 2)
        let deleted = list.delete(list.activeID)
        #expect(deleted)
        #expect(list.active.name == "Small")
        #expect(names(list) == ["Balanced", "Small"])
    }

    @Test func presetList_spec4_3_deleteActiveLast_activatesPrevious() {
        var list = list()
        list.activate(position: 3)
        let deleted = list.delete(list.activeID)
        #expect(deleted)
        #expect(list.active.name == "Web")
    }

    @Test func presetList_spec4_3_deleteUnknown_isRefused() {
        var list = list()
        let deleted = list.delete(UUID())
        #expect(!deleted)
        #expect(list.presets.count == 3)
    }

    @Test func presetList_spec4_3_reorder_keepsActive() {
        var list = list()
        let active = list.active
        list.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(names(list) == ["Web", "Small", "Balanced"])
        list.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(names(list) == ["Balanced", "Web", "Small"])
        list.move(list.presets[2].id, to: 0)
        #expect(names(list) == ["Small", "Balanced", "Web"])
        #expect(list.active == active)
    }

    @Test func presetList_spec4_1_namesMayRepeat() {
        var list = list()
        let id = list.presets[1].id
        list.rename(id, to: "Balanced")
        #expect(names(list) == ["Balanced", "Balanced", "Small"])
        #expect(list.presets[0].id != list.presets[1].id)
    }

    @Test func presetList_spec4_3_namedEditChangesOnlyThatPreset_andKeepsId() {
        var list = list()
        let id = list.presets[1].id
        list.setQuality(id, to: 150)
        #expect(list.presets[1].id == id)
        #expect(list.presets[1].quality == 100)
        #expect(list.presets[0].quality == 80)
    }

    @Test func presetList_restorationFallsBackToFirstForUnknownActiveID() throws {
        let restored = try PresetList.restoring(presets: Self.fixture, activeID: UUID())
        #expect(restored.active.name == "Balanced")
    }

    @Test func presetList_spec4_4_acceptsTwentyUniqueIDsAndDuplicateNames() {
        let presets = (0..<PresetList.maxCount).map { index in
            Preset(
                id: UUID(uuidString: String(format: "20000000-0000-4000-8000-%012d", index + 1))!,
                name: "Repeated", quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)
        }
        let list = PresetList(presets: presets, activeID: presets[19].id)
        #expect(list.presets.count == 20)
        #expect(Set(list.presets.map(\.id)).count == 20)
        #expect(list.activeID == presets[19].id)
        #expect(Set(list.presets.map(\.name)) == ["Repeated"])
    }

    @Test func presetList_spec4_4_rejectsDuplicateIDsAtRestorationBoundary() {
        let duplicateID = Self.fixture[0].id
        var presets = Self.fixture
        presets[1] = presets[0]
        #expect(throws: (any Error).self) {
            try PresetList.restoring(presets: presets, activeID: duplicateID)
        }
    }
    @Test func presetList_restorationRejectsEmptyAndOversizedLists() {
        #expect(throws: PresetList.ValidationError.empty) {
            try PresetList.restoring(presets: [], activeID: UUID())
        }
        let presets = (0..<21).map { _ in Self.fixture[0].duplicated(name: "Repeated") }
        #expect(throws: PresetList.ValidationError.tooManyPresets) {
            try PresetList.restoring(presets: presets, activeID: presets[0].id)
        }
    }

}
