import UnderpressuredCore
import Foundation

/// A path the scanner could not inspect; not an image Item or an intentional exclusion.
public struct ScanFailure: Sendable, Hashable {
    public let url: URL
    public let reason: FailReason

    public init(url: URL, reason: FailReason) {
        self.url = url
        self.reason = reason
    }
}

/// Images admitted for processing, intentional exclusions, and paths requiring attention.
public struct ScanResult: Sendable, Hashable {
    public var items: [Item]
    public var failures: [ScanFailure]
    /// Non-image files and explicitly dropped packages or symlinks. Counted, never listed.
    public var ignoredCount: Int

    public init(items: [Item] = [], ignoredCount: Int = 0, failures: [ScanFailure] = []) {
        self.failures = failures
        self.items = items
        self.ignoredCount = ignoredCount
    }
}

/// Scans dropped URLs through `FileAccess`, in drop order. Identifies images by content type and lists each file once.
/// Recurses in name order, excluding hidden children, packages, symlinks, and the Export folder.
/// Explicitly dropped hidden files and folders are accepted. Hidden children remain excluded.
/// Reports unreadable paths separately. Counts explicitly dropped packages and symlinks as ignored. Marks unsupported images and active sources as Skipped.
/// The pipeline checks animation and multi-page TIFFs.
public struct Scanner: Sendable {
    private let files: any FileAccess

    public init(files: any FileAccess) {
        self.files = files
    }

    /// - Parameters:
    ///   - dropped: files and/or folders, in drop order.
    ///   - exportFolder: the Export folder to leave out, if the Destination has one.
    ///   - isActive: whether a source is already Waiting or Processing in the Queue.
    public func scan(
        _ dropped: [URL], exportFolder: URL? = nil, isActive: (URL) -> Bool = { _ in false }
    ) -> ScanResult {
        withoutActuallyEscaping(isActive) { isActive in
            var run = Run(
                files: files, exportPath: exportFolder.map(Self.path), isActive: isActive)
            for url in dropped {
                if Task.isCancelled { break }
                run.scanDropped(url)
            }
            return ScanResult(items: run.items, ignoredCount: run.ignoredCount, failures: run.failures)
        }
    }

    static func path(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private struct Run {
        let files: any FileAccess
        let exportPath: String?
        let isActive: (URL) -> Bool
        var items: [Item] = []
        var failures: [ScanFailure] = []
        var failedPaths: Set<String> = []
        var ignoredCount = 0
        var seen: Set<SourceIdentity.Key> = []

        init(files: any FileAccess, exportPath: String?, isActive: @escaping (URL) -> Bool) {
            self.files = files
            self.exportPath = exportPath
            self.isActive = isActive
        }

        mutating func scanDropped(_ url: URL) {
            guard !Task.isCancelled else { return }
            let attributes: FileAttributes
            do { attributes = try files.attributes(of: url) }
            catch { recordFailure(url, error); return }
            guard !Task.isCancelled else { return }
            switch attributes.kind {
            case .symlink:
                ignoredCount += 1
            case .directory:
                if attributes.isPackage || Scanner.path(url) == exportPath {
                    ignoredCount += 1
                } else {
                    scanFolder(url, root: url)
                }
            case .file:
                add(url, attributes, root: nil)
            }
        }

        /// `root` is the dropped folder that all Items found below it record.
        private mutating func scanFolder(_ folder: URL, root: URL) {
            guard !Task.isCancelled else { return }
            let children: [URL]
            do { children = try files.contentsOfDirectory(at: folder) }
            catch { recordFailure(folder, error); return }
            guard !Task.isCancelled else { return }
            for child in children.sorted(by: Scanner.byName) {
                guard !Task.isCancelled else { return }
                if child.lastPathComponent.hasPrefix(".") { continue }
                let attributes: FileAttributes
                do { attributes = try files.attributes(of: child) }
                catch { recordFailure(child, error); continue }
                guard !Task.isCancelled else { return }
                if attributes.isHidden { continue }
                switch attributes.kind {
                case .symlink:
                    continue
                case .directory:
                    if attributes.isPackage || Scanner.path(child) == exportPath { continue }
                    scanFolder(child, root: root)
                case .file:
                    add(child, attributes, root: root)
                }
            }
        }

        private mutating func recordFailure(_ url: URL, _ error: FileAccessError) {
            guard !Task.isCancelled, failedPaths.insert(Scanner.path(url)).inserted else { return }
            failures.append(ScanFailure(url: url, reason: error.failReason))
            PipelineLog.error(source: url, stage: nil, message: "intake.\(error.failReason.diagnosticID)")
        }

        private mutating func add(_ url: URL, _ attributes: FileAttributes, root: URL?) {
            guard !Task.isCancelled else { return }
            let caseSensitive = (try? files.isCaseSensitiveVolume(at: url)) ?? true
            let identity = SourceIdentity(
                source: url, attributes: attributes, caseSensitive: caseSensitive)
            guard !Task.isCancelled, seen.isDisjoint(with: identity.keys) else { return }
            seen.formUnion(identity.keys)
            let state: ItemState
            switch attributes.contentType {
            case .notAnImage:
                ignoredCount += 1
                return
            case .unsupported(let kind):
                state = .finished(.skipped(.unsupported(kind), notes: []))
            case .accepted:
                state = isActive(url) ? .finished(.skipped(.alreadyInQueue, notes: [])) : .waiting
            }
            items.append(Item(
                source: url, droppedRoot: root, state: state,
                sourceAttributes: attributes, sourceCaseSensitive: caseSensitive))
        }
    }

    /// Name order that doesn't depend on the locale: numbers by value, case ignored, then exact.
    static func byName(_ a: URL, _ b: URL) -> Bool {
        let x = a.lastPathComponent
        let y = b.lastPathComponent
        switch x.compare(y, options: [.numeric, .caseInsensitive]) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return x < y
        }
    }
}
