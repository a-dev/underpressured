import Foundation

extension Batch {
    /// Snapshot the current Preset name, settings, Output Format, and Destination into a Batch.
    public init(
        activePreset: Preset, outputFormat: OutputFormat, destination: Destination,
        items: [Item], ignoredCount: Int = 0
    ) {
        self.init(
            settings: activePreset.settings, outputFormat: outputFormat,
            destination: destination, items: items, ignoredCount: ignoredCount,
            presetName: activePreset.name)
    }
}
