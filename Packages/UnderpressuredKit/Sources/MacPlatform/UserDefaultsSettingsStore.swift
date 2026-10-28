import Foundation
import UnderpressuredCore
import UnderpressuredApplication

/// Stores `AppSettings` in `UserDefaults` with independent fallbacks for invalid values.
/// `StoredPresetsV1` handles the persisted Preset schema and validation. Export folders use plain paths because the app is not sandboxed.
/// Retain missing folder paths so the Batch reports "Export folder unavailable".
@MainActor
public final class UserDefaultsSettingsStore: SettingsStore {
    private enum Key {
        static let presets = "app.underpressured.presets"
        static let destinationKind = "app.underpressured.destination.kind"
        static let exportFolder = "app.underpressured.destination.exportFolderPath"
        static let moveToTrash = "app.underpressured.destination.moveToTrash"
        static let all = [presets, destinationKind, exportFolder, moveToTrash]
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings? {
        guard Key.all.contains(where: { defaults.object(forKey: $0) != nil }) else { return nil }
        return AppSettings(presets: loadPresets(), destination: loadDestination())
    }

    public func save(_ settings: AppSettings) {
        let stored = StoredPresetsV1(presets: settings.presets.presets, activePresetID: settings.presets.activeID)
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Key.presets)
        }
        defaults.set(Self.name(of: settings.destination.kind), forKey: Key.destinationKind)
        if let folder = settings.destination.exportFolder {
            defaults.set(folder.path(percentEncoded: false), forKey: Key.exportFolder)
        } else {
            defaults.removeObject(forKey: Key.exportFolder)
        }
        defaults.set(settings.destination.moveToTrash, forKey: Key.moveToTrash)
    }

    private func loadPresets() -> PresetList {
        guard let data = defaults.data(forKey: Key.presets),
            let stored = try? JSONDecoder().decode(StoredPresetsV1.self, from: data),
            let list = try? PresetList.restoring(presets: stored.presets, activeID: stored.activePresetID)
        else { return .starter }
        return list
    }

    private func loadDestination() -> DestinationSettings {
        let initial = DestinationSettings.initial
        let kind: DestinationSettings.Kind =
            switch defaults.string(forKey: Key.destinationKind) {
            case "exportFolder": .exportFolder
            case "replaceOriginals": .replaceOriginals
            default: initial.kind
            }
        let folder = defaults.string(forKey: Key.exportFolder)
            .flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
        let trash = defaults.object(forKey: Key.moveToTrash) as? Bool ?? initial.moveToTrash
        return DestinationSettings(kind: kind, exportFolder: folder, moveToTrash: trash)
    }

    private static func name(of kind: DestinationSettings.Kind) -> String {
        switch kind {
        case .replaceOriginals: "replaceOriginals"
        case .exportFolder: "exportFolder"
        }
    }
}
