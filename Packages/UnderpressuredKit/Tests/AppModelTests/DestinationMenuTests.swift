import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

@MainActor
@Suite struct DestinationMenuTests {
    let folder = URL(filePath: "/tmp/Optimized", directoryHint: .isDirectory)

    @Test func startsOnReplaceOriginals() {
        let model = makeModel()
        #expect(model.destinationTitle == "Replace originals")
        #expect(model.isReplaceOriginalsChecked)
        #expect(model.showsMoveToTrash)
        #expect(model.rememberedExportFolderTitle == nil)
        #expect(model.outputFormat == .jpeg)
        #expect(model.outputFormatChoices.map(\.title) == ["Original", "JPEG", "PNG"])
    }

    @Test func choosingAFolderSelectsExportAndHidesTrash() {
        let model = makeModel()
        model.setMoveToTrash(true)
        model.chooseExportFolder(folder)
        #expect(model.destinationTitle == "→ Optimized")
        #expect(!model.isReplaceOriginalsChecked)
        #expect(model.isRememberedExportFolderChecked)
        #expect(!model.showsMoveToTrash)
        #expect(model.destination.destination == .exportFolder(folder))
    }

    @Test func switchingBackRestoresTrashAndKeepsTheFolder() {
        let model = makeModel()
        model.setMoveToTrash(true)
        model.chooseExportFolder(folder)
        model.chooseReplaceOriginals()
        #expect(model.destinationTitle == "Replace originals")
        #expect(model.destination.moveToTrash)
        #expect(model.rememberedExportFolderTitle == "→ Optimized")
        #expect(!model.isRememberedExportFolderChecked)
        let existingFolder = FileManager.default.temporaryDirectory
        model.chooseExportFolder(existingFolder)
        model.chooseReplaceOriginals()
        #expect(model.chooseRememberedExportFolder())
        #expect(model.destination.destination == .exportFolder(existingFolder))
    }

    @Test func rememberedEntryIsInertWithoutAFolder() {
        let model = makeModel()
        model.chooseRememberedExportFolder()
        #expect(model.destination.kind == .replaceOriginals)
    }

    @Test func invalidRememberedFolderLeavesPreviousModeAndPreferencesUntouched() throws {
        let model = makeModel()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        model.setMoveToTrash(true)
        model.chooseExportFolder(missing)
        model.chooseReplaceOriginals()
        let previous = model.destination
        #expect(!model.chooseRememberedExportFolder())
        #expect(model.destination == previous)
        model.chooseExportFolder(missing)
        let previousExport = model.destination
        #expect(!model.chooseRememberedExportFolder())
        #expect(model.destination == previousExport)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.chooseExportFolder(file)
        model.chooseReplaceOriginals()
        #expect(!model.chooseRememberedExportFolder())
        #expect(model.isReplaceOriginalsChecked)
        #expect(model.destination.moveToTrash)
    }

    @Test func choicesAreSaved() {
        let store = InMemorySettingsStore()
        let model = makeModel(settingsStore: store)
        model.outputFormat = .png
        model.chooseExportFolder(folder)
        let reloaded = makeModel(settingsStore: store)
        #expect(reloaded.outputFormat == .png)
        #expect(reloaded.destinationTitle == "→ Optimized")
    }

    @Test func forgettingTheFolderFallsBackToReplaceOriginals() {
        let model = makeModel()
        model.chooseExportFolder(folder)
        model.forgetExportFolder()
        #expect(model.destination.exportFolder == nil)
        #expect(model.isReplaceOriginalsChecked)
        #expect(model.destination.destination != nil)
    }

    @Test func missingFolderChoiceDoesNotScanOrStartARun() async {
        let model = AppModel(
            queue: Queue(parallelism: 1) { _, _, _, _ in
                Issue.record("Missing destination must not admit work")
                return .cancelled
            },
            intake: { _, _, _ in
                Issue.record("Missing destination must not start a scan")
                return ScanResult(items: [])
            })
        model.destination = DestinationSettings(kind: .exportFolder)
        await model.open([URL(filePath: "/tmp/no-destination.jpg")])
        #expect(model.destination.exportFolder == nil)
        #expect(!model.isRunning && model.rows.isEmpty)
        #expect(model.banner == nil)
    }

    @Test func unavailableRememberedPathIsCapturedWithoutChangingPreferences() async {
        let missing = URL(filePath: "/tmp/underpressured-missing-\(UUID().uuidString)")
        let remembered = DestinationSettings(kind: .exportFolder, exportFolder: missing, moveToTrash: true)
        let store = InMemorySettingsStore(AppSettings(presets: .starter, destination: remembered))
        let model = AppModel(
            queue: Queue(parallelism: 1) { _, context, _, _ in
                #expect(context.destination == .exportFolder(missing))
                return .failed(.exportFolderUnavailable)
            },
            intake: { urls, export, _ in
                #expect(export == missing)
                return ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) })
            }, settingsStore: store)
        #expect(model.destination == remembered)
        await model.open([URL(filePath: "/tmp/unavailable-destination.jpg")])
        await model.untilIdle()
        #expect(model.destination == remembered)
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.stateText == "Failed")
    }

    @Test func badgeKeepsItsNameWhileEditing() {
        let model = makeModel()
        let preset = model.presets.active
        model.editPreset(preset.id)
        model.setPresetName(preset.id, "Renamed")
        #expect(model.badgeTitle(model.presets.active) == preset.name)
        model.closePresetEditor()
        #expect(model.badgeTitle(model.presets.active) == "Renamed")
    }

    @Test func outputFormatBelongsToThePreset() {
        let model = makeModel()
        let first = model.presets.active.id
        model.outputFormat = .jpeg
        let second = model.presets.presets.first { $0.id != first }!.id
        model.activatePreset(second)
        #expect(model.outputFormat == .original)
        model.activatePreset(first)
        #expect(model.outputFormat == .jpeg)
    }

}
