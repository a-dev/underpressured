import Foundation
import Testing

@testable import UnderpressuredCore
@testable import UnderpressuredApplication

@Suite struct BatchSnapshotTests {
    private func makePreset() -> Preset {
        Preset(
            name: "Web", quality: 80, lossless: false, resizeRule: .maxLongEdge(2000),
            keepMetadata: true)
    }

    private func makeItems() -> [Item] {
        [Item(source: URL(fileURLWithPath: "/tmp/a.jpg"), droppedRoot: nil)]
    }

    @Test func batch_spec7_1_presetEditsAfterwardsDoNotChangeBatch() {
        var preset = makePreset()
        let batch = Batch(
            activePreset: preset, outputFormat: .original,
            destination: .replaceOriginals(moveToTrash: true), items: makeItems())
        let before = batch

        preset.setQuality(10)
        preset.lossless = true
        preset.resizeRule = .none
        preset.keepMetadata = false
        preset.setName("Renamed")

        #expect(batch == before)
        #expect(
            batch.settings
                == EffectiveSettings(
                    quality: 80, lossless: false, resizeRule: .maxLongEdge(2000),
                    keepMetadata: true))
    }

    @Test func batch_spec7_1_outputFormatAndDestinationEditsAfterwardsDoNotChangeBatch() {
        var outputFormat = OutputFormat.jpeg
        var destination = Destination.exportFolder(URL(fileURLWithPath: "/tmp/out"))
        let batch = Batch(
            activePreset: makePreset(), outputFormat: outputFormat, destination: destination,
            items: makeItems())

        outputFormat = .png
        destination = .exportFolder(URL(fileURLWithPath: "/tmp/other"))
        destination = .replaceOriginals(moveToTrash: false)

        #expect(batch.outputFormat == .jpeg)
        #expect(batch.destination == .exportFolder(URL(fileURLWithPath: "/tmp/out")))
    }

    @Test func batch_spec7_1_trashOptionIsCaptured() {
        var destination = Destination.replaceOriginals(moveToTrash: true)
        let batch = Batch(
            activePreset: makePreset(), outputFormat: .original, destination: destination,
            items: makeItems())
        destination = .replaceOriginals(moveToTrash: false)
        #expect(batch.destination == .replaceOriginals(moveToTrash: true))
        _ = destination
    }

    @Test func batch_spec7_1_recordsNoPresetName() {
        let preset = makePreset()
        let batch = Batch(
            activePreset: preset, outputFormat: .original,
            destination: .replaceOriginals(moveToTrash: false), items: makeItems(),
            ignoredCount: 2)
        #expect(batch.settings == preset.settings)
        #expect(batch.ignoredCount == 2)
        #expect(batch.items.count == 1)
    }
}
