import UnderpressuredApplication
import Foundation
import Synchronization
import Testing

/// Records only exact destinations returned by a successful operation; never searches Trash.
public final class OwnedTrashItems: Sendable {
    private let items = Mutex<[URL]>([])
    public init() {}
    public var urls: [URL] { items.withLock { $0 } }

    public func capture(_ operation: () throws -> URL) rethrows -> URL {
        let url = try operation()
        items.withLock { $0.append(url) }
        return url
    }

    public func cleanup() {
        items.withLock { urls in
            for url in urls {
                do { try FileManager.default.removeItem(at: url) }
                catch { Issue.record("Could not remove owned Trash item \(url): \(error)") }
            }
            urls.removeAll()
        }
    }
}
