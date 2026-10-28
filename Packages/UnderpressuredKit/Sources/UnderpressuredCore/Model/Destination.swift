import Foundation

/// Where results are written (spec §6). Not part of a Preset.
public enum Destination: Sendable, Hashable {
    case replaceOriginals(moveToTrash: Bool)
    case exportFolder(URL)
}
