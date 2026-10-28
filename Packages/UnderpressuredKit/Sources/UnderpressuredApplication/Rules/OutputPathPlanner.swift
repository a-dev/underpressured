import UnderpressuredCore
import Foundation

/// Where one Item's result goes (spec §6). A plan, not I/O: the writer creates the folders.
public struct OutputPlan: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Replace originals, same format: the result takes the source's place (§6.1).
        case replaceSource
        /// A new file at a free path.
        case newFile
        /// The app's own earlier output in the Export folder, refreshed in place (§6.3).
        case overwriteMarked(expected: DestinationVersion)
    }

    public var path: URL
    public var kind: Kind
    /// Missing folders to create, parents first (§6.2).
    public var foldersToCreate: [URL]
}

/// Reserve output paths to prevent collisions between Items. Use one planner per active Run.
/// Read files through `FileAccess`.
public struct OutputPathPlanner: Sendable {
    private let fileAccess: any FileAccess
    private var reserved: Set<String> = []

    var reservedPathCount: Int { reserved.count }

    public init(fileAccess: any FileAccess) {
        self.fileAccess = fileAccess
    }

    /// - Parameters:
    ///   - source: the Item's source file.
    ///   - droppedRoot: the dropped folder it was found in, or nil for a loose file.
    ///   - outputFileName: the name from Output Format resolution (§5), e.g. `a.jpg`.
    ///   - sameFormat: whether the resolved format equals the source's format.
    public mutating func plan(
        source: URL, droppedRoot: URL?, outputFileName: String, sameFormat: Bool,
        destination: Destination
    ) throws(FileAccessError) -> OutputPlan {
        switch destination {
        case .replaceOriginals:
            if sameFormat {
                reserve(source, caseSensitive: try caseSensitive(source))
                return OutputPlan(path: source, kind: .replaceSource, foldersToCreate: [])
            }
            let folder = source.deletingLastPathComponent()
            return try planFree(in: folder, fileName: outputFileName, allowMarkedOverwrite: false, folders: [])
        case .exportFolder(let export):
            let folder = Self.mirroredFolder(source: source, droppedRoot: droppedRoot, export: export)
            let folders = missingFolders(from: export, to: folder)
            return try planFree(in: folder, fileName: outputFileName, allowMarkedOverwrite: true, folders: folders)
        }
    }

    /// `<Export>/<dropped folder>/<relative path>`, or `<Export>/` for a loose file (§6.2).
    static func mirroredFolder(source: URL, droppedRoot: URL?, export: URL) -> URL {
        guard let droppedRoot else { return export }
        let rootComponents = droppedRoot.standardizedFileURL.pathComponents
        let parentComponents = source.deletingLastPathComponent().standardizedFileURL.pathComponents
        var folder = export.appending(path: droppedRoot.lastPathComponent, directoryHint: .isDirectory)
        for component in parentComponents.dropFirst(rootComponents.count) {
            folder.append(path: component, directoryHint: .isDirectory)
        }
        return folder
    }

    /// `a.jpg` → `a-2.jpg`; a name without an extension gets the number at the end.
    static func numbered(_ fileName: String, _ number: Int) -> String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
            return "\(fileName)-\(number)"
        }
        return "\(fileName[..<dot])-\(number)\(fileName[dot...])"
    }

    private mutating func planFree(
        in folder: URL, fileName: String, allowMarkedOverwrite: Bool, folders: [URL]
    ) throws(FileAccessError) -> OutputPlan {
        // A folder that doesn't exist yet lives on the volume of its nearest existing ancestor.
        let caseSensitive = try caseSensitive(nearestExisting(folder))
        var number = 1
        while true {
            let name = number == 1 ? fileName : Self.numbered(fileName, number)
            let candidate = folder.appending(path: name, directoryHint: .notDirectory)
            number += 1
            if reserved.contains(key(candidate, caseSensitive: caseSensitive)) { continue }
            if !fileAccess.fileExists(at: candidate) {
                reserve(candidate, caseSensitive: caseSensitive)
                return OutputPlan(path: candidate, kind: .newFile, foldersToCreate: folders)
            }
            if allowMarkedOverwrite, let expected = ownOutput(candidate) {
                reserve(candidate, caseSensitive: caseSensitive)
                return OutputPlan(path: candidate, kind: .overwriteMarked(expected: expected), foldersToCreate: folders)
            }
        }
    }

    /// The file carries a valid Optimization mark: it's the app's own earlier output (§6.3).
    private func ownOutput(_ url: URL) -> DestinationVersion? {
        guard let attributes = try? fileAccess.attributes(of: url), attributes.kind == .file,
              let stored = try? fileAccess.markedOutput(at: url)
        else { return nil }
        guard stored.mark.isValid(for: attributes) else { return nil }
        return stored.version(for: attributes)
    }

    /// List all missing folders for each Item because parallel Items cannot rely on another Item creating them.
    /// Repeated folder creation is harmless.
    private func missingFolders(from export: URL, to folder: URL) -> [URL] {
        var missing: [URL] = []
        var current = folder
        while current.standardizedFileURL.path != export.standardizedFileURL.path,
              current.pathComponents.count > export.pathComponents.count {
            if !fileAccess.fileExists(at: current) { missing.append(current) }
            current = current.deletingLastPathComponent()
        }
        return missing.reversed()
    }

    private func nearestExisting(_ folder: URL) -> URL {
        var current = folder
        while !fileAccess.fileExists(at: current), current.pathComponents.count > 1 {
            current = current.deletingLastPathComponent()
        }
        return current
    }

    private func caseSensitive(_ url: URL) throws(FileAccessError) -> Bool {
        try fileAccess.isCaseSensitiveVolume(at: url)
    }

    private mutating func reserve(_ url: URL, caseSensitive: Bool) {
        reserved.insert(key(url, caseSensitive: caseSensitive))
    }

    private func key(_ url: URL, caseSensitive: Bool) -> String {
        let path = url.standardizedFileURL.path
        return caseSensitive ? path : path.lowercased()
    }
}
