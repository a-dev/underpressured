import Foundation
import Synchronization

/// One item-replacement folder per volume, reused for every temporary file.
/// A sandboxed app can write there even when only the target file, not its folder, was granted.
final class TemporaryFolders: Sendable {
    private let folders = Mutex<[URL: URL]>([:])

    /// The folder for `url`'s volume, or nil when the volume offers none.
    func folder(near url: URL) -> URL? {
        let parent = url.deletingLastPathComponent()
        guard let volume = try? parent.resourceValues(forKeys: [.volumeURLKey]).volume else { return nil }
        if let cached = folders.withLock({ $0[volume] }) { return cached }
        guard let created = try? FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true)
        else { return nil }
        return folders.withLock { folders in
            if let raced = folders[volume] {
                try? FileManager.default.removeItem(at: created)
                return raced
            }
            folders[volume] = created
            return created
        }
    }

    /// Drop a folder that disappeared, so the next request creates a new one.
    func forget(_ folder: URL) {
        folders.withLock { folders in
            folders = folders.filter { $0.value != folder }
        }
    }

    var all: [URL] { folders.withLock { Array($0.values) } }
}
