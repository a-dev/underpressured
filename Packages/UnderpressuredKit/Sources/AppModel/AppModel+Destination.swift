import UnderpressuredApplication
import Foundation
import UnderpressuredCore

extension OutputFormat {
    /// The Output Format picker's label for this choice (§5).
    public var title: String {
        switch self {
        case .original: String(localized: "Original", bundle: .module, comment: "Output format or destination menu label.")
        case .jpeg: "JPEG"
        case .png: "PNG"
        }
    }
}

extension AppModel {
    /// The Output Format picker's choices, in menu order (§5).
    public var outputFormatChoices: [OutputFormat] { OutputFormat.allCases }

    /// The Destination menu's label: String(localized: "Replace originals", bundle: .module, comment: "Output format or destination menu label.") or "→ <Export folder name>" (§6.2).
    public var destinationTitle: String {
        switch destination.kind {
        case .replaceOriginals: String(localized: "Replace originals", bundle: .module, comment: "Output format or destination menu label.")
        case .exportFolder: destination.exportFolder.map { String(localized: "→ \($0.lastPathComponent)", bundle: .module, comment: "Export folder menu label. Placeholder is a user-selected folder name; preserve it.") } ?? Self.exportEntryTitle
        }
    }

    /// The label of the entry that always opens the folder picker (§6.2).
    public static let exportEntryTitle = String(localized: "Export to folder…", bundle: .module, comment: "Output format or destination menu label.")

    public var isReplaceOriginalsChecked: Bool { destination.kind == .replaceOriginals }

    /// The remembered Export folder as a menu entry ("→ Optimized"), if one was ever chosen.
    public var rememberedExportFolderTitle: String? {
        destination.exportFolder.map { String(localized: "→ \($0.lastPathComponent)", bundle: .module, comment: "Export folder menu label. Placeholder is a user-selected folder name; preserve it.") }
    }

    /// Whether the remembered Export folder entry is the selected Destination.
    public var isRememberedExportFolderChecked: Bool { destination.kind == .exportFolder }

    /// **Move originals to Trash** is available only under Replace originals (§6.1).
    public var showsMoveToTrash: Bool { destination.kind == .replaceOriginals }

    public func chooseReplaceOriginals() { destination.kind = .replaceOriginals }

    /// Called with the folder the picker returned; remembers it and selects Export folder.
    public func chooseExportFolder(_ url: URL) {
        destination.exportFolder = url
        destination.kind = .exportFolder
    }

    /// Selects the remembered Export folder without re-opening the picker.
    @discardableResult
    public func chooseRememberedExportFolder() -> Bool {
        guard let folder = destination.exportFolder,
              let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey]),
              values.isDirectory == true, values.isWritable == true else { return false }
        destination.kind = .exportFolder
        return true
    }

    /// Forget the Export folder and select Replace originals.
    public func forgetExportFolder() {
        destination.exportFolder = nil
        destination.kind = .replaceOriginals
    }

    public func setMoveToTrash(_ on: Bool) { destination.moveToTrash = on }
}
