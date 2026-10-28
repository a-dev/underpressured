import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

@MainActor
@Suite struct PresetBarTests {
    private func names(_ model: AppModel) -> [String] { model.presets.presets.map(\.name) }
    private func id(_ model: AppModel, _ index: Int) -> Preset.ID { model.presets.presets[index].id }

    @Test func clickActivatesAndSaves() {
        let store = InMemorySettingsStore()
        let model = makeModel(settingsStore: store)
        let web = id(model, 1)
        model.activatePreset(web)
        #expect(model.presets.activeID == web)
        #expect(store.load()?.presets.activeID == web)
    }

    @Test func activateByPosition() {
        let model = makeModel()
        model.activatePreset(position: 4)
        #expect(model.presets.active.name == "Screenshots PNG")
        model.activatePreset(position: 9)
        #expect(model.presets.active.name == "Screenshots PNG")
    }

    @Test func penOpensPopoverWithoutActivating() {
        let model = makeModel()
        model.editPreset(id(model, 2))
        #expect(model.editingPresetID == id(model, 2))
        #expect(model.presets.active.name == "Balanced JPEG")
        model.closePresetEditor()
        #expect(model.editingPresetID == nil)
        model.editActivePreset()
        #expect(model.editingPresetID == model.presets.activeID)
    }

    @Test func editsApplyImmediatelyAndAreClamped() {
        let store = InMemorySettingsStore()
        let model = makeModel(settingsStore: store)
        let web = id(model, 1)
        model.setPresetName(web, "  Photos  ")
        model.setPresetQuality(web, 250)
        model.setPresetLossless(web, true)
        model.setPresetKeepMetadata(web, true)
        model.setPresetResizeKind(web, .maxWidth)
        model.setPresetResizePixels(web, 0)
        let saved = store.load()?.presets.presets[1]
        #expect(saved?.name == "Photos")
        #expect(saved?.quality == 100)
        #expect(saved?.lossless == true)
        #expect(saved?.keepMetadata == true)
        #expect(saved?.resizeRule == .maxWidth(1))
    }

    @Test func resizeKindKeepsPixelValue() {
        let model = makeModel()
        let web = id(model, 1)  // Max long edge 2048
        model.setPresetResizeKind(web, .maxHeight)
        #expect(model.presets.preset(id: web)?.resizeRule == .maxHeight(2048))
        model.setPresetResizePixels(web, 900)
        model.setPresetResizeKind(web, .none)
        model.setPresetResizePixels(web, 500)
        #expect(model.presets.preset(id: web)?.resizeRule == ResizeRule.none)
        model.setPresetResizeKind(web, .maxLongEdge)
        #expect(model.presets.preset(id: web)?.resizeRule == .maxLongEdge(.clamping(AppModel.defaultResizePixels)))
    }

    @Test func qualityIsGreyedWhileLossless() {
        let model = makeModel()
        let web = id(model, 1)
        #expect(model.isQualityEnabled(web))
        model.setPresetLossless(web, true)
        #expect(!model.isQualityEnabled(web))
    }

    @Test func emptyNameRevertsOnClose() {
        let model = makeModel()
        let web = id(model, 1)
        model.editPreset(web)
        model.setPresetName(web, "We")
        model.setPresetName(web, "W")
        model.setPresetName(web, "")
        model.setPresetName(web, "   ")
        model.closePresetEditor()
        #expect(model.presets.preset(id: web)?.name == "Web")
    }

    @Test func plusCopiesActiveAfterOriginalActivatesAndOpensPopover() {
        let model = makeModel()
        model.activatePreset(id(model, 1))
        model.addPreset()
        #expect(names(model) == ["Balanced JPEG", "Web", "Web 2", "Small", "Screenshots PNG"])
        #expect(model.presets.active.name == "Web 2")
        #expect(model.editingPresetID == model.presets.activeID)
    }

    @Test func duplicateActivatesCopy() {
        let model = makeModel()
        model.duplicatePreset(id(model, 0))
        #expect(names(model) == ["Balanced JPEG", "Balanced JPEG 2", "Web", "Small", "Screenshots PNG"])
        #expect(model.presets.active.name == "Balanced JPEG 2")
        #expect(model.editingPresetID == nil)
    }

    @Test func deleteActivatesNeighbourAndClosesItsPopover() {
        let model = makeModel()
        let balanced = id(model, 0)
        model.editPreset(balanced)
        model.deletePreset(balanced)
        #expect(names(model) == ["Web", "Small", "Screenshots PNG"])
        #expect(model.presets.active.name == "Web")
        #expect(model.editingPresetID == nil)
        model.activatePreset(id(model, 1))
        model.deletePreset(id(model, 1))
        #expect(model.presets.active.name == "Screenshots PNG")
    }

    @Test func lastPresetCannotBeDeleted() {
        let model = makeModel()
        model.deletePreset(id(model, 0))
        model.deletePreset(id(model, 0))
        model.deletePreset(id(model, 0))
        let last = id(model, 0)
        #expect(!model.canDeletePreset(last))
        model.deletePreset(last)
        #expect(names(model) == ["Screenshots PNG"])
    }

    @Test func dragReorders() {
        let store = InMemorySettingsStore()
        let model = makeModel(settingsStore: store)
        model.movePreset(id(model, 0), onto: id(model, 2))
        #expect(names(model) == ["Web", "Small", "Balanced JPEG", "Screenshots PNG"])
        model.movePreset(id(model, 2), onto: id(model, 0))
        #expect(names(model) == ["Balanced JPEG", "Web", "Small", "Screenshots PNG"])
        #expect(store.load()?.presets.presets.map(\.name) == ["Balanced JPEG", "Web", "Small", "Screenshots PNG"])
        #expect(model.presets.active.name == "Balanced JPEG")
    }

    @Test func addingStopsAtTheLimit() {
        let model = makeModel()
        while model.canAddPreset { model.addPreset() }
        #expect(model.presets.presets.count == PresetList.maxCount)
        model.addPreset()
        model.duplicatePreset(id(model, 0))
        #expect(model.presets.presets.count == PresetList.maxCount)
    }

    @Test func activePresetCanBeEditedAtTheLimit() {
        let model = makeModel()
        while model.canAddPreset { model.addPreset() }
        model.closePresetEditor()
        let before = model.presets
        model.addPreset()
        #expect(model.presets == before)
        #expect(model.editingPresetID == nil)
        model.editActivePreset()
        #expect(model.editingPresetID == before.activeID)
        model.setPresetName(before.activeID, "Menu edit")
        #expect(model.presets.active.name == "Menu edit")
    }

    @Test func activationUsesIdentityAfterDuplicateNamesAndReorder() {
        let model = makeModel()
        let first = id(model, 0)
        let target = id(model, 1)
        model.setPresetName(first, "Same")
        model.setPresetName(target, "Same")
        model.movePreset(target, onto: first)
        model.activatePreset(target)
        #expect(model.presets.activeID == target)
        model.activatePreset(target)
        #expect(model.presets.activeID == target)
        model.deletePreset(target)
        model.activatePreset(target)
        #expect(model.presets.activeID != target)
    }

    @Test func resetPresetsRestoresStartersAndIsUndoable() {
        let store = InMemorySettingsStore()
        let model = makeModel(settingsStore: store)
        model.deletePreset(id(model, 0))
        model.addPreset()
        model.resetPresets()
        #expect(names(model) == Preset.starters.map(\.name))
        #expect(model.presets.activeID == id(model, 0))
        #expect(store.load()?.presets.presets.map(\.name) == Preset.starters.map(\.name))
    }
}
