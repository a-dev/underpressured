import UnderpressuredCore
import Foundation

/// File operations used by Application. `LocalFileAccess` implements them. Tests use an in-memory double.
public protocol FileAccess: Sendable {
    // MARK: Reading

    /// The direct children of a folder, symlinks not followed. Order is unspecified.
    func contentsOfDirectory(at url: URL) throws(FileAccessError) -> [URL]
    /// Attributes of the item itself (for a symlink: the link, not its target).
    func attributes(of url: URL) throws(FileAccessError) -> FileAttributes
    func fileExists(at url: URL) -> Bool
    func readData(at url: URL) throws(FileAccessError) -> Data
    /// Whether names on the volume holding `url` compare case-sensitively.
    func isCaseSensitiveVolume(at url: URL) throws(FileAccessError) -> Bool
    /// Read a stored mark with its opaque commit token. Raw persisted bytes stay in the adapter.
    func markedOutput(at url: URL) throws(FileAccessError) -> MarkedOutput?

    // MARK: Writing

    /// Store domain facts using the adapter-owned mark representation.
    func setOptimizationMark(_ mark: OptimizationMark, at url: URL) throws(FileAccessError)
    /// Writes `data` to a new temporary file on the same volume as `url` and returns its location.
    func writeTemporaryFile(_ data: Data, near url: URL) throws(FileAccessError) -> URL
    func createDirectory(at url: URL) throws(FileAccessError)
    /// Moves `source` to `destination`, failing if `destination` exists.
    func moveItem(at source: URL, to destination: URL) throws(FileAccessError)
    /// Atomically puts `replacement` in place of `original`.
    func replaceItem(at original: URL, withItemAt replacement: URL) throws(FileAccessError)
    /// Revalidate a marked destination within the implementation's filesystem coordination, then replace it.
    /// This is the commit boundary; success means the output is visible even if later source cleanup fails.
    func replaceMarkedItem(at original: URL, withItemAt replacement: URL, expected: DestinationVersion) throws(FileAccessError)
    func copyItem(at source: URL, to destination: URL) throws(FileAccessError)
    func removeItem(at url: URL) throws(FileAccessError)
    /// Whether `url`'s volume has a Trash (spec §6.1).
    func hasTrash(forItemAt url: URL) -> Bool
    func trashItem(at url: URL) throws(FileAccessError)
    /// Copies creation date, modification date and Finder tags from `source` to `destination` (§7.3 step 9).
    func copyDatesAndTags(from source: URL, to destination: URL) throws(FileAccessError)
    /// Copy the POSIX mode and ACL so output permissions do not exceed source permissions.
    /// Call last because the destination may become read-only.
    func copyPermissions(from source: URL, to destination: URL) throws(FileAccessError)
}

public enum FileAccessError: Error, Sendable, Hashable {
    case notFound
    case alreadyExists
    case permissionDenied
    case diskFull
    case noTrash
    case destinationChanged
    case other(String)

    /// The user-facing reason when a file operation fails.
    public var failReason: FailReason {
        switch self {
        case .permissionDenied: .noPermission
        case .diskFull: .diskFull
        case .noTrash: .noTrash
        case .destinationChanged: .destinationChanged
        case .notFound: .fileNotFound
        case .alreadyExists: .fileAlreadyExists
        case .other: .fileIOFailed
        }
    }
}

/// Authorization to refresh one specific marked regular file, captured during planning.
public struct DestinationVersion: Sendable, Hashable {
    public let identity: UInt64
    public let size: Int64
    public let modificationDate: Date
    private let markBytes: Data

    public init(attributes: FileAttributes, opaqueMarkToken: Data) {
        identity = attributes.fileIdentity
        size = attributes.size
        modificationDate = attributes.modificationDate
        self.markBytes = opaqueMarkToken
    }

    public func matches(
        _ attributes: FileAttributes, markBytes currentMarkBytes: Data?, markFacts: OptimizationMark?
    ) -> Bool {
        attributes.kind == .file && attributes.fileIdentity == identity && attributes.size == size
            && attributes.modificationDate == modificationDate && currentMarkBytes == markBytes
            && markFacts?.isValid(for: attributes) == true
    }
}

/// Domain mark facts plus the opaque authorization required to safely refresh that destination.
public struct MarkedOutput: Sendable, Hashable {
    public let mark: OptimizationMark
    private let opaqueMarkToken: Data

    public init(mark: OptimizationMark, opaqueMarkToken: Data) {
        self.mark = mark
        self.opaqueMarkToken = opaqueMarkToken
    }

    public func version(for attributes: FileAttributes) -> DestinationVersion {
        DestinationVersion(attributes: attributes, opaqueMarkToken: opaqueMarkToken)
    }
}
