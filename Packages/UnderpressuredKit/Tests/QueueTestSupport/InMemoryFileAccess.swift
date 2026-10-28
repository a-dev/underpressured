@testable import LocalFileSystem
import UnderpressuredApplication
import Foundation
import Synchronization
import UnderpressuredCore
import UniformTypeIdentifiers

/// An in-memory `FileAccess` for tests: one simulated volume holding files, folders and symlinks.
///
/// - Items are keyed by standardized path. Lookups fold case unless `setCaseSensitive(true)` is
///   called, as APFS does by default, so `A.jpg` finds `a.jpg`. An item keeps the spelling it was created with.
/// - Every created item gets a new `fileIdentity`. Moves keep it; copies and replacements get a new one.
/// - Writes stamp dates from `now`, which tests advance to exercise change detection.
/// - Failure injection (`fail(_:on:for:)`) is checked before anything else. It matches the URL a call
///   names as its target:
///   - `.read`: `contentsOfDirectory`, `attributes`, `readData`, `extendedAttribute`,
///     `isCaseSensitiveVolume`, and the source of `copyDatesAndTags`.
///   - `.write`: `setExtendedAttribute`, `writeTemporaryFile` (the `near` URL), `createDirectory`,
///     the destination of `moveItem`, `copyItem` and `copyDatesAndTags`, and the original of `replaceItem`.
///   - `.move`: the source of `moveItem`. `.copy`: the source of `copyItem`.
///   - `.replace`: the original of `replaceItem`, after checked-replacement validation.
///   - `.remove` and `.trash`: `removeItem` and `trashItem`.
public final class InMemoryFileAccess: FileAccess, @unchecked Sendable {
    public enum Operation: Sendable, Hashable, CaseIterable {
        case listDirectory, read, write, move, copy, remove, trash, replace
    }

    private let state: Mutex<State>

    public init() {
        state = Mutex(State())
    }

    // MARK: Builders and test helpers

    /// The clock that writes stamp modification dates from.
    public var now: Date {
        get { state.withLock { $0.now } }
        set { state.withLock { $0.now = newValue } }
    }

    /// Whether names compare case-sensitively. The default is case-insensitive, like APFS.
    public func setCaseSensitive(_ isCaseSensitive: Bool) {
        state.withLock { $0.caseSensitive = isCaseSensitive }
    }

    /// Whether the volume has a Trash. The default is yes.
    public func setHasTrash(_ hasTrash: Bool) {
        state.withLock { $0.hasTrash = hasTrash }
    }

    /// Adds a file, creating missing parent folders. An existing item at `url` gets the new contents.
    public func addFile(
        _ url: URL, data: Data = Data(), contentType: UTType? = nil, hidden: Bool = false,
        modificationDate: Date? = nil, creationDate: Date? = nil
    ) {
        state.withLock {
            $0.addItem(
                url, kind: .file, data: data, contentType: contentType, isHidden: hidden,
                creationDate: creationDate, modificationDate: modificationDate)
        }
    }

    /// Adds a folder, creating missing parent folders.
    public func addDirectory(_ url: URL, hidden: Bool = false, isPackage: Bool = false) {
        state.withLock { $0.addItem(url, kind: .directory, isHidden: hidden, isPackage: isPackage) }
    }

    /// Adds a symlink. The target is stored as given and is not required to exist.
    public func addSymlink(_ url: URL, to target: URL) {
        state.withLock { $0.addItem(url, kind: .symlink, symlinkTarget: target) }
    }

    /// Makes `fail` throw `error` for calls of `operation` that name `url` as their target.
    public func fail(_ error: FileAccessError, on url: URL, for operation: Operation) {
        state.withLock { $0.setFailure(error, on: url, for: operation) }
    }

    /// The contents of the file at `url`, or nil if no file is there. Symlinks are not followed.
    public func data(at url: URL) -> Data? {
        state.withLock { (s: inout State) -> Data? in
            guard let node = s.node(at: url), node.kind == .file else { return nil }
            return node.data
        }
    }

    /// Whether anything, including a symlink, exists at `url`.
    public func exists(_ url: URL) -> Bool {
        state.withLock { $0.node(at: url) != nil }
    }

    /// Every item's path, sorted. The root is not included.
    public var allPaths: [String] {
        state.withLock { $0.nodes.keys.filter { $0 != "/" }.sorted() }
    }

    /// Every URL passed to `trashItem` that succeeded, in order.
    public var trashed: [URL] {
        state.withLock { $0.trashed }
    }

    /// Removal/Trash targets, including attempts that throw, in call order.
    public var cleanupAttempts: [URL] {
        state.withLock { $0.cleanupAttempts }
    }

    /// The Finder tags of the item at `url`, empty if there is no item.
    public func tags(at url: URL) -> [String] {
        state.withLock { $0.node(at: url)?.tags ?? [] }
    }

    /// Sets the Finder tags of an existing item.
    public func setTags(_ tags: [String], at url: URL) {
        state.withLock { (s: inout State) -> Void in
            guard let key = s.lookup(State.path(url)) else {
                preconditionFailure("No item at \(url.path) to tag")
            }
            s.nodes[key]!.tags = tags
        }
    }

    /// Runs `body` under the lock with typed errors, which `withLock` doesn't infer on its own.
    private func locked<R>(_ body: (inout State) throws(FileAccessError) -> R) throws(FileAccessError) -> R {
        try state.withLock { (s: inout State) throws(FileAccessError) -> R in try body(&s) }
    }

    // MARK: FileAccess, reading

    public func contentsOfDirectory(at url: URL) throws(FileAccessError) -> [URL] {
        try locked { (s: inout State) throws(FileAccessError) in try s.contentsOfDirectory(at: url) }
    }

    public func attributes(of url: URL) throws(FileAccessError) -> FileAttributes {
        try locked { (s: inout State) throws(FileAccessError) in try s.attributes(of: url) }
    }

    public func fileExists(at url: URL) -> Bool {
        exists(url)
    }

    public func readData(at url: URL) throws(FileAccessError) -> Data {
        try locked { (s: inout State) throws(FileAccessError) in try s.readData(at: url) }
    }

    public func isCaseSensitiveVolume(at url: URL) throws(FileAccessError) -> Bool {
        try locked { (s: inout State) throws(FileAccessError) in try s.isCaseSensitiveVolume(at: url) }
    }

    public func markedOutput(at url: URL) throws(FileAccessError) -> MarkedOutput? {
        try locked { (s: inout State) throws(FileAccessError) in
            guard let bytes = try s.extendedAttribute(StoredOptimizationMark.attributeName, at: url),
                  let mark = StoredOptimizationMark.decode(bytes)
            else { return nil }
            return MarkedOutput(mark: mark, opaqueMarkToken: bytes)
        }
    }

    public func extendedAttribute(_ name: String, at url: URL) throws(FileAccessError) -> Data? {
        try locked { (s: inout State) throws(FileAccessError) in try s.extendedAttribute(name, at: url) }
    }

    // MARK: FileAccess, writing

    public func setExtendedAttribute(_ name: String, to value: Data, at url: URL) throws(FileAccessError) {
        try locked { (s: inout State) throws(FileAccessError) in try s.setExtendedAttribute(name, to: value, at: url) }
    }

    public func setOptimizationMark(_ mark: OptimizationMark, at url: URL) throws(FileAccessError) {
        try setExtendedAttribute(
            StoredOptimizationMark.attributeName, to: StoredOptimizationMark.encode(mark), at: url)
    }

    public func writeTemporaryFile(_ data: Data, near url: URL) throws(FileAccessError) -> URL {
        try locked { (s: inout State) throws(FileAccessError) in try s.writeTemporaryFile(data, near: url) }
    }

    public func createDirectory(at url: URL) throws(FileAccessError) {
        try locked { (s: inout State) throws(FileAccessError) in try s.createDirectory(at: url) }
    }

    public func moveItem(at source: URL, to destination: URL) throws(FileAccessError) {
        try locked { (s: inout State) throws(FileAccessError) in try s.moveItem(at: source, to: destination) }
    }

    public func replaceItem(at original: URL, withItemAt replacement: URL) throws(FileAccessError) {
        try locked { (s: inout State) throws(FileAccessError) in try s.replaceItem(at: original, withItemAt: replacement) }
    }

    public func replaceMarkedItem(
        at original: URL, withItemAt replacement: URL, expected: DestinationVersion
    ) throws(FileAccessError) {
        try locked { (s: inout State) throws(FileAccessError) in
            guard let attributes = try? s.attributes(of: original),
                  let currentBytes = try? s.extendedAttribute(StoredOptimizationMark.attributeName, at: original),
                  expected.matches(
                    attributes, markBytes: currentBytes,
                    markFacts: StoredOptimizationMark.decode(currentBytes))
            else { throw .destinationChanged }
            try s.replaceItem(at: original, withItemAt: replacement)
        }
    }

    public func copyItem(at source: URL, to destination: URL) throws(FileAccessError) {
        try locked { (s: inout State) throws(FileAccessError) in try s.copyItem(at: source, to: destination) }
    }

    public func removeItem(at url: URL) throws(FileAccessError) {
        try locked { (s: inout State) throws(FileAccessError) in
            s.cleanupAttempts.append(url)
            try s.removeItem(at: url)
        }
    }

    public func hasTrash(forItemAt url: URL) -> Bool {
        state.withLock { $0.hasTrash }
    }

    public func trashItem(at url: URL) throws(FileAccessError) {
        try locked { (s: inout State) throws(FileAccessError) in
            s.cleanupAttempts.append(url)
            try s.trashItem(at: url)
        }
    }

    public func copyDatesAndTags(from source: URL, to destination: URL) throws(FileAccessError) {
        try locked { (s: inout State) throws(FileAccessError) in try s.copyDatesAndTags(from: source, to: destination) }
    }

    /// The double doesn't model permissions; it only checks that both items are reachable.
    public func copyPermissions(from source: URL, to destination: URL) throws(FileAccessError) {
        try locked { (s: inout State) throws(FileAccessError) in
            try s.check(.read, source)
            try s.check(.write, destination)
            _ = try s.existingNode(source)
            _ = try s.existingNode(destination)
        }
    }
}

// MARK: - Storage

private struct Node {
    /// The standardized path, which is also the item's key in `State.nodes`.
    var path: String
    var kind: FileAttributes.Kind
    var isHidden: Bool
    var isPackage: Bool
    var contentType: UTType?
    var data: Data
    /// The standardized path a symlink points at.
    var symlinkTarget: String?
    var xattrs: [String: Data] = [:]
    var tags: [String] = []
    var creationDate: Date
    var modificationDate: Date
    var fileIdentity: UInt64

    init(
        path: String, kind: FileAttributes.Kind, isHidden: Bool = false, isPackage: Bool = false,
        contentType: UTType? = nil, data: Data = Data(), symlinkTarget: String? = nil,
        creationDate: Date, modificationDate: Date, fileIdentity: UInt64
    ) {
        self.path = path
        self.kind = kind
        self.isHidden = isHidden
        self.isPackage = isPackage
        self.contentType = contentType
        self.data = data
        self.symlinkTarget = symlinkTarget
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.fileIdentity = fileIdentity
    }
}

private struct Failure {
    var path: String
    var operation: InMemoryFileAccess.Operation
    var error: FileAccessError
}

private struct State {
    var cleanupAttempts: [URL] = []
    typealias Operation = InMemoryFileAccess.Operation

    var nodes: [String: Node] = [:]
    var caseSensitive = false
    var hasTrash = true
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var trashed: [URL] = []
    var failures: [Failure] = []
    private var nextIdentity: UInt64 = 1

    init() {
        nodes["/"] = Node(
            path: "/", kind: .directory, creationDate: now, modificationDate: now,
            fileIdentity: allocateIdentity())
    }

    // MARK: Paths

    static func path(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    static func parent(of path: String) -> String? {
        guard path != "/", let slash = path.lastIndex(of: "/") else { return nil }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    static func name(of path: String) -> String {
        String(path[path.index(after: path.lastIndex(of: "/")!)...])
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    func fold(_ path: String) -> String {
        caseSensitive ? path : path.lowercased()
    }

    /// The key of the item at `path`, matching case-insensitively on a case-insensitive volume.
    func lookup(_ path: String) -> String? {
        if nodes[path] != nil { return path }
        guard !caseSensitive else { return nil }
        let folded = path.lowercased()
        return nodes.keys.first { $0.lowercased() == folded }
    }

    func node(at url: URL) -> Node? {
        lookup(Self.path(url)).flatMap { nodes[$0] }
    }

    func key(for path: String) throws(FileAccessError) -> String {
        guard let key = lookup(path) else { throw .notFound }
        return key
    }

    func key(of url: URL) throws(FileAccessError) -> String {
        try key(for: Self.path(url))
    }

    func existingNode(_ url: URL) throws(FileAccessError) -> Node {
        let key = try key(of: url)
        return nodes[key]!
    }

    /// The node a symlink chain ends at. Gives up after 16 links.
    func resolvedNode(_ url: URL) throws(FileAccessError) -> Node {
        var node = try existingNode(url)
        var hops = 0
        while node.kind == .symlink {
            hops += 1
            guard hops <= 16, let target = node.symlinkTarget else {
                throw .other("too many levels of symbolic links")
            }
            node = try existingNode(URL(fileURLWithPath: target))
        }
        return node
    }

    /// The path for a new item at `url`. Its parent folder must already exist.
    func newPath(for url: URL) throws(FileAccessError) -> String {
        let path = Self.path(url)
        guard let parent = Self.parent(of: path) else { throw .alreadyExists }
        let folder = nodes[try key(for: parent)]!
        guard folder.kind == .directory else { throw .other("not a folder") }
        return Self.join(folder.path, Self.name(of: path))
    }

    /// The item and everything under it, by key.
    func subtreeKeys(of key: String) -> [String] {
        nodes.keys.filter { $0 == key || $0.hasPrefix(key + "/") }
    }

    func requireNotRoot(_ key: String) throws(FileAccessError) {
        guard key != "/" else { throw .other("the root folder can't be changed") }
    }

    func requireNotInside(_ path: String, _ key: String) throws(FileAccessError) {
        guard !path.hasPrefix(key + "/") else { throw .other("a folder can't go inside itself") }
    }

    // MARK: Failures

    func check(_ operation: Operation, _ url: URL) throws(FileAccessError) {
        let path = fold(Self.path(url))
        if let failure = failures.last(where: { $0.operation == operation && fold($0.path) == path }) {
            throw failure.error
        }
    }

    mutating func setFailure(_ error: FileAccessError, on url: URL, for operation: Operation) {
        let path = Self.path(url)
        failures.removeAll { $0.operation == operation && $0.path == path }
        failures.append(Failure(path: path, operation: operation, error: error))
    }

    // MARK: Mutation helpers

    mutating func allocateIdentity() -> UInt64 {
        defer { nextIdentity += 1 }
        return nextIdentity
    }

    mutating func insert(_ node: Node) {
        nodes[node.path] = node
    }

    mutating func removeSubtree(_ key: String) {
        for removed in subtreeKeys(of: key) {
            nodes[removed] = nil
        }
    }

    /// Moves the item at `key` and everything under it to `newRoot`, keeping identities.
    mutating func relocate(_ key: String, to newRoot: String) {
        let moving = subtreeKeys(of: key).map { nodes.removeValue(forKey: $0)! }
        for var node in moving {
            node.path = newRoot + String(node.path.dropFirst(key.count))
            nodes[node.path] = node
        }
    }

    mutating func ensureFolder(_ path: String) {
        guard lookup(path) == nil, let parent = Self.parent(of: path) else { return }
        ensureFolder(parent)
        let folder = nodes[lookup(parent)!]!
        insert(
            Node(
                path: Self.join(folder.path, Self.name(of: path)), kind: .directory,
                creationDate: now, modificationDate: now, fileIdentity: allocateIdentity()))
    }

    mutating func addItem(
        _ url: URL, kind: FileAttributes.Kind, data: Data = Data(), contentType: UTType? = nil,
        isHidden: Bool = false, isPackage: Bool = false, symlinkTarget: URL? = nil,
        creationDate: Date? = nil, modificationDate: Date? = nil
    ) {
        let path = Self.path(url)
        guard let parent = Self.parent(of: path) else { return }  // the root always exists
        ensureFolder(parent)
        let target = symlinkTarget.map { Self.path($0) }
        let stamp = now
        if let key = lookup(path) {
            var node = nodes[key]!
            node.kind = kind
            node.data = data
            node.contentType = contentType
            node.isHidden = isHidden
            node.isPackage = isPackage
            node.symlinkTarget = target
            node.creationDate = creationDate ?? stamp
            node.modificationDate = modificationDate ?? stamp
            nodes[key] = node
            return
        }
        let folder = nodes[lookup(parent)!]!
        precondition(folder.kind == .directory, "\(parent) is not a folder")
        insert(
            Node(
                path: Self.join(folder.path, Self.name(of: path)), kind: kind, isHidden: isHidden,
                isPackage: isPackage, contentType: contentType, data: data, symlinkTarget: target,
                creationDate: creationDate ?? stamp, modificationDate: modificationDate ?? stamp,
                fileIdentity: allocateIdentity()))
    }

    // MARK: FileAccess

    func contentsOfDirectory(at url: URL) throws(FileAccessError) -> [URL] {
        try check(.listDirectory, url)
        try check(.read, url)
        let folder = try existingNode(url)
        guard folder.kind == .directory else { throw .other("not a folder") }
        return nodes.values
            .filter { Self.parent(of: $0.path) == folder.path }
            .map { URL(fileURLWithPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    func attributes(of url: URL) throws(FileAccessError) -> FileAttributes {
        try check(.read, url)
        let node = try existingNode(url)
        return FileAttributes(
            kind: node.kind, isHidden: node.isHidden, isPackage: node.isPackage,
            contentType: FileContentClassifier.classify(node.contentType),
            size: node.kind == .file ? Int64(node.data.count) : 0,
            creationDate: node.creationDate, modificationDate: node.modificationDate,
            fileIdentity: node.fileIdentity)
    }

    func readData(at url: URL) throws(FileAccessError) -> Data {
        try check(.read, url)
        let node = try resolvedNode(url)
        guard node.kind == .file else { throw .other("not a file") }
        return node.data
    }

    func isCaseSensitiveVolume(at url: URL) throws(FileAccessError) -> Bool {
        try check(.read, url)
        return caseSensitive
    }

    func extendedAttribute(_ name: String, at url: URL) throws(FileAccessError) -> Data? {
        try check(.read, url)
        return try existingNode(url).xattrs[name]
    }

    mutating func setExtendedAttribute(_ name: String, to value: Data, at url: URL) throws(FileAccessError) {
        try check(.write, url)
        let key = try key(of: url)
        nodes[key]!.xattrs[name] = value
    }

    mutating func writeTemporaryFile(_ data: Data, near url: URL) throws(FileAccessError) -> URL {
        try check(.write, url)
        let stamp = now
        if lookup("/.tmp") == nil {
            insert(
                Node(
                    path: "/.tmp", kind: .directory, isHidden: true, creationDate: stamp,
                    modificationDate: stamp, fileIdentity: allocateIdentity()))
        }
        let path = "/.tmp/" + UUID().uuidString
        insert(
            Node(
                path: path, kind: .file, isHidden: true, data: data, creationDate: stamp,
                modificationDate: stamp, fileIdentity: allocateIdentity()))
        return URL(fileURLWithPath: path)
    }

    mutating func createDirectory(at url: URL) throws(FileAccessError) {
        try check(.write, url)
        guard lookup(Self.path(url)) == nil else { throw .alreadyExists }
        let path = try newPath(for: url)
        let stamp = now
        insert(
            Node(
                path: path, kind: .directory, creationDate: stamp, modificationDate: stamp,
                fileIdentity: allocateIdentity()))
    }

    mutating func moveItem(at source: URL, to destination: URL) throws(FileAccessError) {
        try check(.move, source)
        try check(.write, destination)
        let sourceKey = try key(of: source)
        try requireNotRoot(sourceKey)
        // A case-only rename finds the source itself, which is allowed.
        if let existingKey = lookup(Self.path(destination)), existingKey != sourceKey {
            throw .alreadyExists
        }
        let newRoot = try newPath(for: destination)
        try requireNotInside(newRoot, sourceKey)
        relocate(sourceKey, to: newRoot)
    }

    mutating func replaceItem(at original: URL, withItemAt replacement: URL) throws(FileAccessError) {
        try check(.replace, original)
        try check(.write, original)
        let originalKey = try key(of: original)
        let replacementKey = try key(of: replacement)
        try requireNotRoot(originalKey)
        try requireNotInside(replacementKey, originalKey)
        guard replacementKey != originalKey else { throw .other("an item can't replace itself") }
        removeSubtree(originalKey)
        relocate(replacementKey, to: originalKey)
    }

    mutating func copyItem(at source: URL, to destination: URL) throws(FileAccessError) {
        try check(.copy, source)
        try check(.write, destination)
        let sourceKey = try key(of: source)
        try requireNotRoot(sourceKey)
        guard lookup(Self.path(destination)) == nil else { throw .alreadyExists }
        let newRoot = try newPath(for: destination)
        try requireNotInside(newRoot, sourceKey)
        let stamp = now
        let originals = subtreeKeys(of: sourceKey).map { nodes[$0]! }
        for original in originals {
            var duplicate = original
            duplicate.path = newRoot + String(original.path.dropFirst(sourceKey.count))
            duplicate.fileIdentity = allocateIdentity()
            duplicate.creationDate = stamp
            duplicate.modificationDate = stamp
            insert(duplicate)
        }
    }

    mutating func removeItem(at url: URL) throws(FileAccessError) {
        try check(.remove, url)
        let key = try key(of: url)
        try requireNotRoot(key)
        removeSubtree(key)
    }

    mutating func trashItem(at url: URL) throws(FileAccessError) {
        try check(.trash, url)
        guard hasTrash else { throw .noTrash }
        let key = try key(of: url)
        try requireNotRoot(key)
        trashed.append(url.standardizedFileURL)
        removeSubtree(key)
    }

    mutating func copyDatesAndTags(from source: URL, to destination: URL) throws(FileAccessError) {
        try check(.read, source)
        try check(.write, destination)
        let original = try existingNode(source)
        let destinationKey = try key(of: destination)
        nodes[destinationKey]!.creationDate = original.creationDate
        nodes[destinationKey]!.modificationDate = original.modificationDate
        nodes[destinationKey]!.tags = original.tags
    }
}
