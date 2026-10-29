import UnderpressuredCore
import Foundation

/// Folders where Replace originals creates a converted file beside a loose source (spec §6).
/// Dropping a file grants only that file, so intake asks for these folders before admission.
public enum SiblingOutputFolders {
    /// Distinct parent folders in Item order. Items in dropped folders and decided Items need none.
    public static func needed(for items: [Item], outputFormat: OutputFormat, destination: Destination) -> [URL] {
        guard case .replaceOriginals = destination else { return [] }
        var seen: Set<String> = []
        var folders: [URL] = []
        for item in items where item.droppedRoot == nil && item.state == .waiting {
            guard let source = item.scannedFormat, case .write(let output) = outputFormat.resolve(for: source),
                  output.imageFormat != source else { continue }
            let folder = item.source.deletingLastPathComponent()
            if seen.insert(folder.standardizedFileURL.path).inserted { folders.append(folder) }
        }
        return folders
    }
}
