import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

@MainActor
@Suite struct PresetUndoTests {
    private func ids(_ model: AppModel) -> [Preset.ID] { model.presets.presets.map(\.id) }
    private func names(_ model: AppModel) -> [String] { model.presets.presets.map(\.name) }

    private func modelWithUndo(store: InMemorySettingsStore = InMemorySettingsStore()) -> (AppModel, UndoManager) {
        let model = makeModel(settingsStore: store)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.presetUndoManager = undoManager
        return (model, undoManager)
    }

    @Test func adjacentMovementPreservesIdentityActivationPersistenceAndHistory() {
        let store = InMemorySettingsStore()
        let model = makeModel(settingsStore: store)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.presetUndoManager = undo
        let original = model.presets.presets
        let active = model.presets.activeID
        let web = original[1].id
        #expect(model.canMovePresetEarlier(web))
        #expect(model.canMovePresetLater(web))
        model.movePresetEarlier(web)
        #expect(model.presets.presets == [original[1], original[0], original[2], original[3]])
        #expect(!model.canMovePresetEarlier(web))
        #expect(model.presets.activeID == active)
        #expect(model.presetFocusID == web)
        #expect(store.load()?.presets == model.presets)
        #expect(undo.undoActionName == "Move Preset")
        undo.undo()
        #expect(model.presets.presets == original)
        undo.redo()
        #expect(model.presets.presets[0].id == web)
        #expect(store.load()?.presets == model.presets)
        model.movePresetLater(web)
        model.movePresetLater(web)
        model.movePresetLater(web)
        #expect(model.presets.presets == [original[0], original[2], original[3], original[1]])
        #expect(!model.canMovePresetLater(web))
        #expect(model.presets.activeID == active)
        model.activatePreset(position: 4)
        #expect(model.presets.activeID == web)
    }

    @Test func starterRenameAndDuplicateMaterializeNamesAndUndoRestoresIdentity() throws {
        let store = InMemorySettingsStore()
        let model = makeModel(settingsStore: store)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.presetUndoManager = undo
        let starter = model.presets.presets[1]
        #expect(starter.starterID == .web)

        model.duplicatePreset(starter.id)
        let starterCopy = model.presets.active
        #expect(starterCopy.name == "\(starter.displayName) 2" && starterCopy.starterID == nil)
        #expect(store.load()?.presets.presets.contains(starterCopy) == true)
        undo.undo()
        #expect(model.presets.preset(id: starterCopy.id) == nil)
        undo.redo()
        #expect(model.presets.preset(id: starterCopy.id) == starterCopy)
        undo.removeAllActions()

        model.setPresetName(starter.id, "Веб-фото")
        let renamed = try #require(model.presets.preset(id: starter.id))
        #expect(renamed.name == "Веб-фото" && renamed.starterID == nil)
        #expect(store.load()?.presets.presets.first(where: { $0.id == starter.id }) == renamed)

        undo.undo()
        #expect(model.presets.preset(id: starter.id) == starter)
        undo.redo()
        #expect(model.presets.preset(id: starter.id)?.name == "Веб-фото")

        undo.removeAllActions()
        model.duplicatePreset(starter.id)
        let copy = model.presets.active
        #expect(copy.name == "Веб-фото 2" && copy.starterID == nil)
        #expect(store.load()?.presets.presets.contains(copy) == true)
        undo.undo()
        #expect(model.presets.preset(id: copy.id) == nil)
        undo.redo()
        #expect(model.presets.preset(id: copy.id) == copy)
    }

    @Test func impossibleAdjacentMovesLeaveStateAndHistoryUnchanged() {
        let (model, undo) = modelWithUndo()
        let original = model.presets
        let first = original.presets[0].id
        let last = original.presets.last!.id
        let unknown = UUID()
        #expect(!model.canMovePresetEarlier(first))
        #expect(!model.canMovePresetLater(last))
        #expect(!model.canMovePresetEarlier(unknown))
        #expect(!model.canMovePresetLater(unknown))
        model.movePresetEarlier(first)
        model.movePresetLater(last)
        model.movePresetEarlier(unknown)
        model.movePresetLater(unknown)
        #expect(model.presets == original)
        #expect(model.presetFocusID == nil)
        #expect(!undo.canUndo)
        #expect(AccessibilityText.presetPosition(name: "Web", position: 2, count: 3)
                == "Web preset, position 2 of 3")
    }

    @Test func structuralChangesUndoAndRedoWithStableIdentityAndOrder() {
        let (model, undo) = modelWithUndo()
        let original = model.presets.presets
        let balanced = original[0].id

        model.duplicatePreset(balanced)
        let duplicated = model.presets.presets
        #expect(duplicated.count == original.count + 1)
        #expect(duplicated[0] == original[0])
        #expect(duplicated[2...].map(\.id) == original[1...].map(\.id))
        undo.undo()
        #expect(model.presets.presets == original)
        undo.redo()
        #expect(model.presets.presets == duplicated)

        let beforeMove = model.presets.presets
        model.movePreset(beforeMove[0].id, onto: beforeMove[2].id)
        let moved = model.presets.presets
        undo.undo()
        #expect(model.presets.presets == beforeMove)
        undo.redo()
        #expect(model.presets.presets == moved)
    }

    @Test func deletingFirstMiddleAndLastRestoresTheExactPresetList() {
        let initialized = makeModel().presets.presets
        #expect(initialized.count == 4)
        #expect(initialized.map(\.starterID) == [.balanced, .web, .small, .screenshots])
        for index in initialized.indices {
            let store = InMemorySettingsStore()
            let (model, undo) = modelWithUndo(store: store)
            let original = model.presets.presets
            model.deletePreset(original[index].id)
            let remaining = original.enumerated().filter { $0.offset != index }.map { $0.element }
            #expect(model.presets.presets == remaining)
            #expect(store.load()?.presets == model.presets)
            undo.undo()
            #expect(model.presets.presets == original)
            #expect(store.load()?.presets == model.presets)
            undo.redo()
            #expect(model.presets.presets == remaining)
            #expect(store.load()?.presets == model.presets)
        }
    }

    @Test func deletingActivePresetPreservesExplicitActivationAcrossUndoAndRedo() {
        let (model, undo) = modelWithUndo()
        let web = model.presets.presets[1].id
        let small = model.presets.presets[2].id
        model.activatePreset(web)
        undo.removeAllActions()

        model.deletePreset(web)
        let fallback = model.presets.activeID
        #expect(fallback != web)
        model.activatePreset(fallback)
        undo.undo()
        #expect(model.presets.preset(id: web) != nil)
        #expect(model.presets.activeID == fallback)
        undo.redo()
        #expect(model.presets.preset(id: web) == nil)
        #expect(model.presets.activeID == fallback)

        undo.undo()
        model.activatePreset(small)
        undo.redo()
        #expect(model.presets.activeID == small)
        undo.undo()
        #expect(model.presets.activeID == small)
    }

    @Test func deletingActivePresetAtEveryPositionRestoresItsActiveState() {
        let initialized = makeModel().presets.presets
        #expect(initialized.count == 4)
        #expect(initialized.map(\.starterID) == [.balanced, .web, .small, .screenshots])
        for index in initialized.indices {
            let store = InMemorySettingsStore()
            let (model, undo) = modelWithUndo(store: store)
            let original = model.presets.presets
            let activeID = original[index].id
            model.activatePreset(activeID)
            undo.removeAllActions()

            model.deletePreset(activeID)
            let fallbackID = model.presets.activeID
            let fallbackIndex = index == original.count - 1 ? index - 1 : index + 1
            let remaining = original.filter { $0.id != activeID }
            #expect(fallbackID == original[fallbackIndex].id)
            #expect(model.presets.presets == remaining)
            #expect(store.load()?.presets == model.presets)
            undo.undo()
            #expect(model.presets.presets == original)
            #expect(model.presets.activeID == activeID)
            #expect(store.load()?.presets == model.presets)
            undo.redo()
            #expect(model.presets.presets == remaining)
            #expect(model.presets.activeID == fallbackID)
            #expect(store.load()?.presets == model.presets)
        }
    }

    @Test func deletingActiveLastPreservesLaterExplicitActivationBeforeUndoOrRedo() throws {
        // Each combination owns its model, persistent store, and undo history.
        for activateFallback in [true, false] {
            for activateBeforeUndo in [true, false] {
                let store = InMemorySettingsStore()
                let (model, undo) = modelWithUndo(store: store)
                let original = model.presets.presets
                #expect(original.count == 4)
                let deleted = try #require(original.last)
                let fallback = original[original.count - 2]
                let explicit = activateFallback ? fallback : original[0]
                model.activatePreset(deleted.id)
                undo.removeAllActions()
                model.deletePreset(deleted.id)
                let remaining = Array(original.dropLast())
                #expect(model.presets.presets == remaining)
                #expect(model.presets.activeID == fallback.id)
                #expect(store.load()?.presets == model.presets)

                if activateBeforeUndo { model.activatePreset(explicit.id) }
                undo.undo()
                #expect(model.presets.presets == original)
                #expect(model.presets.activeID == (activateBeforeUndo ? explicit.id : deleted.id))
                #expect(store.load()?.presets == model.presets)
                if !activateBeforeUndo { model.activatePreset(explicit.id) }
                undo.redo()
                #expect(model.presets.presets == remaining)
                #expect(model.presets.activeID == explicit.id)
                #expect(store.load()?.presets == model.presets)
                undo.undo()
                #expect(model.presets.presets == original)
                #expect(model.presets.activeID == explicit.id)
                #expect(store.load()?.presets == model.presets)
            }
        }
    }

    @Test func undoingDeletionDoesNotReopenTheDismissedEditor() {
        let (model, undo) = modelWithUndo()
        let web = model.presets.presets[1].id
        model.editPreset(web)
        model.deletePreset(web)
        #expect(model.editingPresetID == nil)

        undo.undo()
        #expect(model.presets.preset(id: web) != nil)
        #expect(model.editingPresetID == nil)
    }

    @Test func explicitActivationOfDifferentSurvivorWinsOverDeletionHistory() {
        let (model, undo) = modelWithUndo()
        let original = model.presets.presets
        model.activatePreset(original[1].id)
        model.deletePreset(original[1].id)
        #expect(model.presets.activeID == original[2].id)
        model.activatePreset(original[0].id)
        undo.undo()
        #expect(model.presets.activeID == original[0].id)
        undo.redo()
        #expect(model.presets.activeID == original[0].id)
        #expect(model.presets.preset(id: original[1].id) == nil)
    }

    @Test func editingOperationGroupsQualityAndNameChangesAndEmptyNameReverts() {
        let (model, undo) = modelWithUndo()
        let web = model.presets.presets[1].id
        let original = model.presets.preset(id: web)!
        model.editPreset(web)
        model.beginPresetEditingOperation("Change Preset Quality")
        model.setPresetQuality(web, 62)
        model.setPresetQuality(web, 68)
        model.setPresetQuality(web, 73)
        model.endPresetEditingOperation()
        model.beginPresetEditingOperation("Rename Preset")
        model.setPresetName(web, " Photos ")
        model.setPresetName(web, "   ")
        model.endPresetEditingOperation()

        let changed = model.presets.preset(id: web)!
        #expect(changed.quality == 73)
        #expect(changed.name == "Web")
        #expect(undo.undoActionName == "Change Preset Quality")
        undo.undo()
        #expect(model.presets.preset(id: web) == original)
        undo.redo()
        #expect(model.presets.preset(id: web) == changed)
    }

    @Test func noOpAndCapacityLimitDoNotRegisterUndoActions() {
        let (model, undo) = modelWithUndo()
        let current = ids(model)
        model.movePreset(current[0], onto: current[0])
        model.setPresetQuality(current[0], model.presets.presets[0].quality.rawValue)
        #expect(!undo.canUndo)

        while model.canAddPreset { model.addPreset() }
        #expect(model.presets.presets.count == PresetList.maxCount)
        undo.removeAllActions()
        model.addPreset()
        model.duplicatePreset(ids(model)[0])
        #expect(model.presets.presets.count == PresetList.maxCount)
        #expect(!undo.canUndo)
    }

    @Test func deleteThenAddAtCapacityCanUndoBothWithoutLosingPresets() {
        let (model, undo) = modelWithUndo()
        while model.canAddPreset { model.addPreset() }
        undo.removeAllActions()
        let fullList = model.presets.presets

        let deletedID = fullList[0].id
        model.deletePreset(deletedID)
        #expect(model.presets.presets.count == PresetList.maxCount - 1)
        model.addPreset()
        #expect(model.presets.presets.count == PresetList.maxCount)

        undo.undo()
        #expect(model.presets.presets.count == PresetList.maxCount - 1)
        undo.undo()
        #expect(model.presets.presets == fullList)
        #expect(model.presets.presets.count == PresetList.maxCount)
    }

    @Test func deletingTheLastPresetIsANoOpWithoutUndo() {
        let (model, undo) = modelWithUndo()
        while model.presets.presets.count > 1 {
            model.deletePreset(model.presets.presets[0].id)
        }
        undo.removeAllActions()
        let last = model.presets.activeID

        model.deletePreset(last)

        #expect(ids(model) == [last])
        #expect(!undo.canUndo)
    }

    @Test func aNewEditAfterUndoDiscardsTheRedoBranch() {
        let (model, undo) = modelWithUndo()
        let initial = ids(model)
        model.movePreset(initial[0], onto: initial[2])
        undo.undo()
        #expect(undo.canRedo)

        model.setPresetQuality(initial[1], 77)
        #expect(!undo.canRedo)
    }

    @Test func resizeValuesRemainClampedWhenUndoingAGroupedEdit() {
        let (model, undo) = modelWithUndo()
        let web = model.presets.presets[1].id
        model.setPresetQuality(web, 250)
        model.setPresetResizeKind(web, .maxWidth)
        let beforePixels = model.presets.preset(id: web)!
        model.beginPresetEditingOperation("Change Preset Size")
        model.setPresetResizePixels(web, 0)
        model.endPresetEditingOperation()

        let changed = model.presets.preset(id: web)!
        #expect(changed.quality == 100)
        #expect(changed.resizeRule == .maxWidth(1))
        undo.undo()
        #expect(model.presets.preset(id: web) == beforePixels)
        undo.redo()
        #expect(model.presets.preset(id: web) == changed)
    }

    @Test func undoAndRedoPersistTheRestoredPresetState() {
        let store = InMemorySettingsStore()
        let model = makeModel(settingsStore: store)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.presetUndoManager = undo
        let original = model.presets.presets

        model.deletePreset(original[1].id)
        undo.undo()
        #expect(store.load()?.presets.presets == original)
        undo.redo()
        #expect(store.load()?.presets.presets == model.presets.presets)
    }
}
