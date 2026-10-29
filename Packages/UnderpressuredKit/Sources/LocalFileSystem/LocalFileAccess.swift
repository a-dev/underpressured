import UnderpressuredApplication
import Darwin
import Foundation
import UnderpressuredCore
import UniformTypeIdentifiers

/// Implements `FileAccess` with FileManager and file-system APIs.
public struct LocalFileAccess: FileAccess {
    private let trashOperation: @Sendable (URL) throws -> URL
    private let temporaryFolders = TemporaryFolders()

    public init() { trashOperation = Self.foundationTrash }

    init(trashOperation: @escaping @Sendable (URL) throws -> URL) {
        self.trashOperation = trashOperation
    }

    /// Temporary files written by this instance that were not yet moved or removed.
    /// Harnesses check this for leftovers, because temporary files live outside the target folders.
    public var pendingTemporaryFiles: [URL] {
        temporaryFolders.all.flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }
    }

    static func foundationTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else {
            throw CocoaError(.fileWriteUnknown)
        }
        return result as URL
    }

    // MARK: Reading

    public func contentsOfDirectory(at url: URL) throws(FileAccessError) -> [URL] {
        // `contentsOfDirectory` lists the folder's own entries and never follows a symlink child.
        try Self.perform {
            try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [])
        }
    }

    public func attributes(of url: URL) throws(FileAccessError) -> FileAttributes {
        // `lstat` describes the item itself, so a symlink is never followed.
        var info = stat()
        let status = Self.withPath(url) { lstat($0, &info) }
        guard status == 0 else { throw Self.error(forErrno: errno) }

        let keys: Set<URLResourceKey> = [
            .isHiddenKey, .isPackageKey, .contentTypeKey, .fileSizeKey,
            .creationDateKey, .contentModificationDateKey,
        ]
        let values = try Self.perform { try url.resourceValues(forKeys: keys) }

        let kind: FileAttributes.Kind
        switch info.st_mode & S_IFMT {
        case S_IFLNK: kind = .symlink
        case S_IFDIR: kind = .directory
        default: kind = .file
        }
        return FileAttributes(
            kind: kind,
            isHidden: values.isHidden ?? false,
            isPackage: kind == .directory && (values.isPackage ?? false),
            contentType: FileContentClassifier.classify(kind == .file ? values.contentType : nil),
            size: Int64(info.st_size),
            creationDate: values.creationDate ?? .distantPast,
            modificationDate: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000),
            fileIdentity: UInt64(info.st_ino), volumeIdentity: UInt64(UInt32(bitPattern: info.st_dev)))
    }

    public func fileExists(at url: URL) -> Bool {
        // `lstat`, not `stat`: a broken symlink is still there.
        var info = stat()
        return Self.withPath(url) { lstat($0, &info) } == 0
    }

    public func readData(at url: URL) throws(FileAccessError) -> Data {
        try Self.perform { try Data(contentsOf: url) }
    }

    public func isCaseSensitiveVolume(at url: URL) throws(FileAccessError) -> Bool {
        let values = try Self.perform {
            try url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        }
        return values.volumeSupportsCaseSensitiveNames ?? false
    }

    public func extendedAttribute(_ name: String, at url: URL) throws(FileAccessError) -> Data? {
        // Size first, then read; retry if the value grew in between.
        for _ in 0..<3 {
            let size = Self.withPath(url) { getxattr($0, name, nil, 0, 0, XATTR_NOFOLLOW) }
            if size < 0 {
                if errno == ENOATTR { return nil }
                throw Self.error(forErrno: errno)
            }
            var buffer = Data(count: size)
            let read = buffer.withUnsafeMutableBytes { bytes in
                Self.withPath(url) {
                    getxattr($0, name, bytes.baseAddress, size, 0, XATTR_NOFOLLOW)
                }
            }
            if read >= 0 { return buffer.prefix(read) }
            if errno == ENOATTR { return nil }
            if errno != ERANGE { throw Self.error(forErrno: errno) }
        }
        throw .other("extended attribute \(name) kept changing")
    }

    // MARK: Writing

    public func setExtendedAttribute(
        _ name: String, to value: Data, at url: URL
    ) throws(FileAccessError) {
        let status = value.withUnsafeBytes { bytes in
            Self.withPath(url) {
                setxattr($0, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
        }
        guard status == 0 else { throw Self.error(forErrno: errno) }
    }

    public func markedOutput(at url: URL) throws(FileAccessError) -> MarkedOutput? {
        guard let bytes = try extendedAttribute(StoredOptimizationMark.attributeName, at: url),
              let mark = StoredOptimizationMark.decode(bytes)
        else { return nil }
        return MarkedOutput(mark: mark, opaqueMarkToken: bytes)
    }

    public func setOptimizationMark(_ mark: OptimizationMark, at url: URL) throws(FileAccessError) {
        try setExtendedAttribute(
            StoredOptimizationMark.attributeName, to: StoredOptimizationMark.encode(mark), at: url)
    }

    /// Prefers the volume's item-replacement folder. Falls back to the target's folder when the volume has none.
    public func writeTemporaryFile(_ data: Data, near url: URL) throws(FileAccessError) -> URL {
        let name = ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        // A second attempt replaces a reused folder that was removed since it was cached.
        for attempt in 1...2 {
            guard let folder = temporaryFolders.folder(near: url) else { break }
            let temporary = folder.appendingPathComponent(name)
            do throws(FileAccessError) {
                try Self.perform { try data.write(to: temporary, options: .withoutOverwriting) }
                return temporary
            } catch .notFound where attempt == 1 {
                temporaryFolders.forget(folder)
            }
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(name)
        try Self.perform { try data.write(to: temporary, options: .withoutOverwriting) }
        return temporary
    }

    public func createDirectory(at url: URL) throws(FileAccessError) {
        try Self.perform {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: false)
        }
    }

    /// Move atomically without overwriting. Preserve dates and extended attributes.
    /// The temporary file and target share a volume.
    public func moveItem(at source: URL, to destination: URL) throws(FileAccessError) {
        try Self.rename(source, to: destination, flags: UInt32(RENAME_EXCL))
    }

    /// Atomically replace `original` with `replacement`, preserving the replacement dates, attributes, and identity.
    /// `FileManager.replaceItemAt` would copy the original attributes instead.
    public func replaceItem(at original: URL, withItemAt replacement: URL) throws(FileAccessError) {
        guard fileExists(at: original) else { throw .notFound }
        try Self.rename(replacement, to: original, flags: 0)
    }

    public func replaceMarkedItem(
        at original: URL, withItemAt replacement: URL, expected: DestinationVersion
    ) throws(FileAccessError) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Void, FileAccessError> = .failure(.destinationChanged)
        coordinator.coordinate(writingItemAt: original, options: .forReplacing, error: &coordinationError) { target in
            do throws(FileAccessError) {
                guard let attributes = try? attributes(of: target) else { throw .destinationChanged }
                let currentBytes = try? extendedAttribute(StoredOptimizationMark.attributeName, at: target)
                let currentMark = currentBytes.flatMap(StoredOptimizationMark.decode)
                guard expected.matches(
                    attributes, markBytes: currentBytes, markFacts: currentMark)
                else { throw .destinationChanged }
                try replaceItem(at: target, withItemAt: replacement)
                result = .success(())
            } catch { result = .failure(error) }
        }
        if let coordinationError { throw Self.map(coordinationError) }
        try result.get()
    }

    public func copyItem(at source: URL, to destination: URL) throws(FileAccessError) {
        try Self.perform { try FileManager.default.copyItem(at: source, to: destination) }
    }

    public func removeItem(at url: URL) throws(FileAccessError) {
        try Self.perform { try FileManager.default.removeItem(at: url) }
    }

    public func hasTrash(forItemAt url: URL) -> Bool {
        // Throws for a volume with no Trash (many network and some external volumes).
        let trash = try? FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false)
        return trash != nil
    }

    public func trashItem(at url: URL) throws(FileAccessError) {
        do {
            _ = try trashOperation(url)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.featureUnsupported.rawValue {
                throw .noTrash
            }
            throw Self.map(error)
        }
    }

    /// Finder tags first, then the dates, so nothing written afterwards moves the modification date.
    public func copyDatesAndTags(from source: URL, to destination: URL) throws(FileAccessError) {
        let values = try Self.perform {
            try source.resourceValues(forKeys: [.tagNamesKey, .creationDateKey, .contentModificationDateKey])
        }
        var tags = URLResourceValues()
        tags.tagNames = values.tagNames ?? []
        var dates = URLResourceValues()
        dates.creationDate = values.creationDate
        dates.contentModificationDate = values.contentModificationDate
        var destination = destination
        try Self.perform {
            try destination.setResourceValues(tags)
            destination.removeAllCachedResourceValues()
            try destination.setResourceValues(dates)
        }
    }

    public func copyPermissions(from source: URL, to destination: URL) throws(FileAccessError) {
        let status = Self.withPath(source) { from in
            Self.withPath(destination) { to in copyfile(from, to, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_NOFOLLOW)) }
        }
        guard status == 0 else { throw Self.error(forErrno: errno) }
    }

    // MARK: Helpers

    private static func withPath<R>(_ url: URL, _ body: (UnsafePointer<CChar>) -> R) -> R {
        url.withUnsafeFileSystemRepresentation { path in
            // Only a non-file URL has no representation; "" then fails the call with ENOENT.
            if let path { return body(path) }
            return "".withCString(body)
        }
    }

    private static func rename(_ source: URL, to destination: URL, flags: UInt32) throws(FileAccessError) {
        let status = withPath(source) { from in
            withPath(destination) { to in renamex_np(from, to, flags) }
        }
        guard status == 0 else { throw error(forErrno: errno) }
    }

    private static func perform<T>(_ body: () throws -> T) throws(FileAccessError) -> T {
        do {
            return try body()
        } catch {
            throw map(error)
        }
    }

    static func error(forErrno code: Int32) -> FileAccessError {
        switch code {
        case ENOENT: .notFound
        case EACCES, EPERM, EROFS: .permissionDenied
        case ENOSPC, EDQUOT: .diskFull
        case EEXIST: .alreadyExists
        default: .other(String(cString: strerror(code)))
        }
    }

    static func map(_ error: any Error) -> FileAccessError {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return Self.error(forErrno: Int32(nsError.code)) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain
        {
            return Self.error(forErrno: Int32(underlying.code))
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: nsError.code) {
            case .fileNoSuchFile, .fileReadNoSuchFile: return .notFound
            case .fileReadNoPermission, .fileWriteNoPermission: return .permissionDenied
            case .fileWriteOutOfSpace: return .diskFull
            case .fileWriteFileExists: return .alreadyExists
            default: break
            }
        }
        return .other(nsError.localizedDescription)
    }
}
