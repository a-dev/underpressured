import Foundation

public enum FileContentType: Sendable, Hashable {
    case accepted(ImageFormat)
    case unsupported(UnsupportedKind)
    case notAnImage
}

/// What Core needs to know about one file-system item.
public struct FileAttributes: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case file
        case directory
        case symlink
    }

    public var kind: Kind
    public var isHidden: Bool
    /// A bundle shown as one file (`.app`, `.photoslibrary`, …).
    public var isPackage: Bool
    /// Non-images and unknown types use `.notAnImage`.
    public var contentType: FileContentType
    public var size: Int64
    public var creationDate: Date
    public var modificationDate: Date
    /// Filesystem device ID, which scopes inode numbers across mounted volumes.
    public var volumeIdentity: UInt64
    /// Stable identity of the file on its volume (inode), for change detection (§10.10).
    public var fileIdentity: UInt64

    public init(
        kind: Kind, isHidden: Bool = false, isPackage: Bool = false, contentType: FileContentType = .notAnImage,
        size: Int64 = 0, creationDate: Date = .distantPast, modificationDate: Date = .distantPast,
        fileIdentity: UInt64 = 0, volumeIdentity: UInt64 = 0
    ) {
        self.kind = kind
        self.isHidden = isHidden
        self.isPackage = isPackage
        self.contentType = contentType
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.volumeIdentity = volumeIdentity
        self.fileIdentity = fileIdentity
    }
}
