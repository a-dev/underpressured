import Foundation
import UnderpressuredCore

/// Remembered preferences, including a selected folder that is currently unavailable.
/// These are separate from the immutable Destination captured for each intake.
public struct DestinationSettings: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case replaceOriginals
        case exportFolder
    }

    public var kind: Kind
    public var exportFolder: URL?
    public var moveToTrash: Bool

    public init(kind: Kind, exportFolder: URL? = nil, moveToTrash: Bool = false) {
        self.kind = kind
        self.exportFolder = exportFolder
        self.moveToTrash = moveToTrash
    }

    /// Replace originals, Trash on, no Export folder chosen yet.
    public static var initial: DestinationSettings { DestinationSettings(kind: .replaceOriginals, moveToTrash: true) }

    /// What an intake captures. nil for Export folder with no folder chosen.
    /// A remembered path is retained even when unavailable: the pipeline reports the
    /// existing destination failure rather than silently choosing another location.
    public var destination: Destination? {
        switch kind {
        case .replaceOriginals: .replaceOriginals(moveToTrash: moveToTrash)
        case .exportFolder: exportFolder.map(Destination.exportFolder)
        }
    }
}
