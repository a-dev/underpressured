import Foundation

/// Sources conflict by normalized path or by filesystem identity (including hard links).
/// Case folding follows the source volume; inode numbers are scoped to their device.
public struct SourceIdentity: Sendable, Hashable {
    public enum Key: Sendable, Hashable {
        case path(String)
        case file(volume: UInt64, inode: UInt64)
    }

    public let keys: Set<Key>

    public init(source: URL, attributes: FileAttributes? = nil, caseSensitive: Bool = true) {
        let path = source.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        var keys: Set<Key> = [.path(caseSensitive ? path : path.lowercased())]
        if let attributes, attributes.fileIdentity != 0 {
            keys.insert(.file(volume: attributes.volumeIdentity, inode: attributes.fileIdentity))
        }
        self.keys = keys
    }
}
