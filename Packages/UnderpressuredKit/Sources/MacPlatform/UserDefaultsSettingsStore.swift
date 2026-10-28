import Foundation
import UnderpressuredCore
import UnderpressuredApplication

/// Stores `AppSettings` in `UserDefaults` with independent fallbacks for invalid values.
/// `StoredPresetsV1` handles the persisted Preset schema and validation.
/// The Export folder is saved as a security-scoped bookmark, so a sandboxed build can reopen it after relaunch.
/// The plain path stays saved beside it: builds without the bookmark key read it, and it is the fallback when the bookmark
/// is missing or cannot be resolved. Retain missing folder paths so the Batch reports "Export folder unavailable".
@MainActor
public final class UserDefaultsSettingsStore: SettingsStore {
    private enum Key {
        static let presets = "app.underpressured.presets"
        static let destinationKind = "app.underpressured.destination.kind"
        static let exportFolder = "app.underpressured.destination.exportFolderPath"
        static let exportFolderBookmark = "app.underpressured.destination.exportFolderBookmark"
        static let moveToTrash = "app.underpressured.destination.moveToTrash"
        static let all = [presets, destinationKind, exportFolder, exportFolderBookmark, moveToTrash]
    }

    private let defaults: UserDefaults
    /// The folder the saved bookmark currently describes, so saving unrelated settings does not rebuild it.
    private var bookmarkedFolder: URL?

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
            saveBookmark(for: folder)
        } else {
            defaults.removeObject(forKey: Key.exportFolder)
            defaults.removeObject(forKey: Key.exportFolderBookmark)
            bookmarkedFolder = nil
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
        let folder = resolveBookmark() ?? defaults.string(forKey: Key.exportFolder)
            .flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
        let trash = defaults.object(forKey: Key.moveToTrash) as? Bool ?? initial.moveToTrash
        return DestinationSettings(kind: kind, exportFolder: folder, moveToTrash: trash)
    }

    /// Creating a bookmark needs current access to the folder. Without it, no bookmark is kept, and the path fallback
    /// leads a sandboxed build to ask for the folder again.
    private func saveBookmark(for folder: URL) {
        guard folder != bookmarkedFolder else { return }
        bookmarkedFolder = nil
        guard let data = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else {
            defaults.removeObject(forKey: Key.exportFolderBookmark)
            return
        }
        defaults.set(data, forKey: Key.exportFolderBookmark)
        bookmarkedFolder = folder
    }

    /// The bookmarked folder with access started, or nil to fall back to the saved path.
    /// Access is kept for the life of the process: Batches captured earlier may still write to a folder the user has since replaced.
    private func resolveBookmark() -> URL? {
        guard let data = defaults.data(forKey: Key.exportFolderBookmark) else { return nil }
        var isStale = false
        guard let folder = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        else { return nil }
        _ = folder.startAccessingSecurityScopedResource()
        bookmarkedFolder = isStale ? nil : folder
        return folder
    }

    private static func name(of kind: DestinationSettings.Kind) -> String {
        switch kind {
        case .replaceOriginals: "replaceOriginals"
        case .exportFolder: "exportFolder"
        }
    }
}
