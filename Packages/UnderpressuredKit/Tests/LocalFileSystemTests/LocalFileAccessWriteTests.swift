import UnderpressuredApplication
import Foundation
import Testing
import QueueTestSupport
import UnderpressuredCore

@testable import LocalFileSystem

/// The write side (spec §7.3 step 9, §8 Safety) in a real temporary folder per test.
final class LocalFileAccessWriteTests {
    let root: URL
    let access = LocalFileAccess()
    private let old = Date(timeIntervalSince1970: 1_600_000_000)
    private let older = Date(timeIntervalSince1970: 1_500_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("up-LocalFileAccessWriteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // A read-only folder must be writable again before it can be removed.
        if let items = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in items {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(path).path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    private func makeSource(_ name: String = "photo.jpg", tags: [String] = ["Red", "Work"]) throws -> URL {
        var source = url(name)
        try Data("original bytes".utf8).write(to: source)
        var values = URLResourceValues()
        values.tagNames = tags
        try source.setResourceValues(values)
        var dates = URLResourceValues()
        dates.creationDate = older
        dates.contentModificationDate = old
        source.removeAllCachedResourceValues()
        try source.setResourceValues(dates)
        return source
    }

    private func tags(_ url: URL) throws -> [String] {
        var url = url
        url.removeAllCachedResourceValues()
        return try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    private func visibleNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: Temporary file

    /// A sandboxed app may hold access to the target alone, so the temporary file stays out of the target's folder.
    @Test func temporaryFile_spec7_3_isHiddenOnTheTargetVolumeOutsideItsFolder() throws {
        let temp = try access.writeTemporaryFile(Data("new".utf8), near: url("photo.jpg"))
        let second = try access.writeTemporaryFile(Data("other".utf8), near: url("other.jpg"))
        #expect(temp.deletingLastPathComponent().standardizedFileURL != root.standardizedFileURL)
        #expect(second.deletingLastPathComponent() == temp.deletingLastPathComponent())
        #expect(try access.attributes(of: temp).volumeIdentity == access.attributes(of: root).volumeIdentity)
        #expect(temp.lastPathComponent.hasPrefix("."))
        #expect(try Data(contentsOf: temp) == Data("new".utf8))
        #expect(try access.attributes(of: temp).isHidden)
        #expect(Set(access.pendingTemporaryFiles.map(\.lastPathComponent)) == [temp.lastPathComponent, second.lastPathComponent])

        try access.moveItem(at: temp, to: url("photo.jpg"))
        try access.removeItem(at: second)
        #expect(access.pendingTemporaryFiles.isEmpty)
        #expect(try visibleNames() == ["photo.jpg"])
    }

    @Test func temporaryFile_aRemovedReusedFolderIsReplaced() throws {
        let first = try access.writeTemporaryFile(Data("a".utf8), near: url("photo.jpg"))
        try FileManager.default.removeItem(at: first.deletingLastPathComponent())
        let second = try access.writeTemporaryFile(Data("b".utf8), near: url("photo.jpg"))
        #expect(try Data(contentsOf: second) == Data("b".utf8))
        #expect(second.deletingLastPathComponent().standardizedFileURL != root.standardizedFileURL)
        try access.removeItem(at: second)
    }

    @Test func readOnlyFolder_spec7_8_noPermissionToWriteHere() throws {
        let folder = url("locked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: folder.appendingPathComponent("photo.jpg"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

        let temp = try access.writeTemporaryFile(Data("new".utf8), near: folder.appendingPathComponent("photo.webp"))
        #expect(throws: FileAccessError.permissionDenied) {
            try self.access.moveItem(at: temp, to: folder.appendingPathComponent("photo.webp"))
        }
        try access.removeItem(at: temp)
        #expect(throws: FileAccessError.permissionDenied) {
            try self.access.createDirectory(at: folder.appendingPathComponent("sub"))
        }
        #expect(FileAccessError.permissionDenied.failReason == .noPermission)
    }

    @Test func errnoMapping_spec7_8_diskFullAndReadOnlyVolume() {
        #expect(LocalFileAccess.error(forErrno: ENOSPC) == .diskFull)
        #expect(LocalFileAccess.error(forErrno: EDQUOT) == .diskFull)
        #expect(LocalFileAccess.error(forErrno: EROFS) == .permissionDenied)
        #expect(FileAccessError.diskFull.failReason == .diskFull)
    }

    // MARK: Dates, tags, mark

    @Test func copyDatesAndTags_spec7_3_keepsCreationModificationAndTags() throws {
        let source = try makeSource()
        let temp = try access.writeTemporaryFile(Data("new".utf8), near: source)
        try access.copyDatesAndTags(from: source, to: temp)
        let attributes = try access.attributes(of: temp)
        #expect(attributes.creationDate == older)
        #expect(attributes.modificationDate == old)
        #expect(try tags(temp) == ["Red", "Work"])
    }

    @Test func setExtendedAttribute_spec7_6_doesNotMoveTheModificationDate() throws {
        let source = try makeSource()
        try access.setExtendedAttribute(StoredOptimizationMark.attributeName, to: Data("mark".utf8), at: source)
        #expect(try access.attributes(of: source).modificationDate == old)
        #expect(try access.extendedAttribute(StoredOptimizationMark.attributeName, at: source) == Data("mark".utf8))
    }

    // MARK: Moving into place

    @Test func replaceItem_spec8_atomicAndKeepsTheReplacementsDatesTagsAndMark() throws {
        let source = try makeSource()
        let temp = try access.writeTemporaryFile(Data("optimized".utf8), near: source)
        try access.copyDatesAndTags(from: source, to: temp)
        try access.setExtendedAttribute(StoredOptimizationMark.attributeName, to: Data("mark".utf8), at: temp)
        let tempIdentity = try access.attributes(of: temp).fileIdentity

        try access.replaceItem(at: source, withItemAt: temp)

        #expect(try Data(contentsOf: source) == Data("optimized".utf8))
        #expect(!access.fileExists(at: temp))
        let attributes = try access.attributes(of: source)
        #expect(attributes.fileIdentity == tempIdentity)
        #expect(attributes.creationDate == older)
        #expect(attributes.modificationDate == old)
        #expect(try tags(source) == ["Red", "Work"])
        #expect(try access.extendedAttribute(StoredOptimizationMark.attributeName, at: source) == Data("mark".utf8))
        #expect(try visibleNames() == ["photo.jpg"])
    }

    @Test func replaceItem_spec8_privateOriginalStaysPrivate() throws {
        let source = try makeSource()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        let temp = try access.writeTemporaryFile(Data("optimized".utf8), near: source)
        try access.copyDatesAndTags(from: source, to: temp)
        try access.setExtendedAttribute(StoredOptimizationMark.attributeName, to: Data("mark".utf8), at: temp)
        try access.copyPermissions(from: source, to: temp)

        try access.replaceItem(at: source, withItemAt: temp)

        let mode = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func replaceItem_missingOriginal_throwsNotFound() throws {
        let temp = try access.writeTemporaryFile(Data("x".utf8), near: url("gone.jpg"))
        #expect(throws: FileAccessError.notFound) { try self.access.replaceItem(at: self.url("gone.jpg"), withItemAt: temp) }
        #expect(access.fileExists(at: temp))
    }

    @Test func moveThenRemove_preservesMovedFileDatesAndTags() throws {
        let source = try makeSource("photo.png")
        let temp = try access.writeTemporaryFile(Data("jpeg".utf8), near: url("photo.jpg"))
        try access.copyDatesAndTags(from: source, to: temp)

        try access.moveItem(at: temp, to: url("photo.jpg"))
        #expect(try visibleNames() == ["photo.jpg", "photo.png"])
        try access.removeItem(at: source)

        #expect(try visibleNames() == ["photo.jpg"])
        #expect(try access.attributes(of: url("photo.jpg")).modificationDate == old)
        #expect(try tags(url("photo.jpg")) == ["Red", "Work"])
    }

    @Test func moveItem_neverOverwrites() throws {
        let existing = try makeSource("photo.jpg")
        let temp = try access.writeTemporaryFile(Data("new".utf8), near: existing)
        #expect(throws: FileAccessError.alreadyExists) { try self.access.moveItem(at: temp, to: existing) }
        #expect(try Data(contentsOf: existing) == Data("original bytes".utf8))
    }

    @Test func moveItem_intoReadOnlyFolder_noPermission() throws {
        let folder = url("locked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let temp = try access.writeTemporaryFile(Data("new".utf8), near: url("x.jpg"))
        #expect(throws: FileAccessError.permissionDenied) {
            try self.access.moveItem(at: temp, to: folder.appendingPathComponent("x.jpg"))
        }
    }

    // MARK: Change detection

    @Test func changeDetection_spec7_3_sizeDateAndIdentityMoveWhenTheFileChanges() throws {
        let source = try makeSource()
        let before = try access.attributes(of: source)

        try Data("someone else wrote this".utf8).write(to: source)
        let rewritten = try access.attributes(of: source)
        #expect(rewritten.size != before.size || rewritten.modificationDate != before.modificationDate)

        // Swapped for another file of the same size and date: only the identity tells.
        let other = try makeSource("other.jpg")
        try FileManager.default.removeItem(at: source)
        try FileManager.default.moveItem(at: other, to: source)
        let swapped = try access.attributes(of: source)
        #expect(swapped.size == before.size && swapped.modificationDate == before.modificationDate)
        #expect(swapped.fileIdentity != before.fileIdentity)
    }

    // MARK: Trash

    @Test func trash_preservesOriginalAtExactReturnedURL() throws {
        let captured = OwnedTrashItems()
        defer { captured.cleanup() }
        let access = LocalFileAccess(trashOperation: { source in
            try captured.capture { try LocalFileAccess.foundationTrash(source) }
        })
        let id = UUID().uuidString
        let source = try makeSource("\(id).jpg")
        let original = Data("original-\(id)".utf8)
        try original.write(to: source)
        try #require(access.hasTrash(forItemAt: source), "Real volume Trash is required")
        try access.trashItem(at: source)
        #expect(!access.fileExists(at: source))
        #expect(captured.urls.count == 1)
        let trashed = try #require(captured.urls.first)
        #expect(try Data(contentsOf: trashed) == original)
    }

    @Test(arguments: [CocoaError.featureUnsupported, .fileWriteNoPermission, .fileNoSuchFile])
    func trash_preservesErrorMapping(code: CocoaError.Code) {
        let access = LocalFileAccess(trashOperation: { _ in throw CocoaError(code) })
        let expected: FileAccessError = code == .featureUnsupported ? .noTrash
            : code == .fileWriteNoPermission ? .permissionDenied : .notFound
        #expect(throws: expected) { try access.trashItem(at: self.url("missing")) }
    }

    @Test(arguments: [false, true])
    func trashCleanup_onlyRemovesOwnedURL_afterSuccessOrFailure(failing: Bool) throws {
        let fakeTrash = url(UUID().uuidString)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: false)
        let owned = fakeTrash.appendingPathComponent("t-\(UUID().uuidString).jpg")
        let sentinel = fakeTrash.appendingPathComponent("trip.jpg")
        let bytes = Data("same-sized-content".utf8)
        try bytes.write(to: owned)
        try bytes.write(to: sentinel)
        func scope() throws {
            let captured = OwnedTrashItems()
            defer { captured.cleanup() }
            _ = captured.capture { owned }
            try #require(!failing, "deliberate later assertion failure")
            #expect(try Data(contentsOf: owned) == bytes)
        }
        if failing {
            withKnownIssue("Exercise deferred cleanup after a required assertion fails") {
                try scope()
            }
        } else { try scope() }
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(try Data(contentsOf: sentinel) == bytes)
    }

}

extension LocalFileAccessWriteTests {
    @Test(arguments: ["unchanged", "edit", "date", "replace", "delete", "symlink", "mark", "renameFailure"])
    func checkedMarkedReplacement(_ change: String) throws {
        let target = try makeSource()
        let originalBytes = try Data(contentsOf: target)
        let attributes = try access.attributes(of: target)
        let settings = EffectiveSettings(quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)
        let mark = OptimizationMark(settings: settings, outputFormat: .jpeg,
                                    size: attributes.size, modificationDate: attributes.modificationDate)
        try access.setOptimizationMark(mark, at: target)
        let stored = try #require(try access.markedOutput(at: target))
        let expected = stored.version(for: attributes)
        let bytes = Data("encoded result".utf8)
        let temporary = try access.writeTemporaryFile(bytes, near: target)
        defer { try? access.removeItem(at: temporary) }
        let other = url("unrelated.jpg")
        try originalBytes.write(to: other)
        switch change {
        case "edit": try Data("edited contents".utf8).write(to: target)
        case "date":
            try Data(originalBytes.reversed()).write(to: target)
            try FileManager.default.setAttributes([.modificationDate: attributes.modificationDate.addingTimeInterval(1)], ofItemAtPath: target.path)
        case "replace":
            try access.removeItem(at: target)
            try access.moveItem(at: other, to: target)
            try FileManager.default.setAttributes([.modificationDate: attributes.modificationDate], ofItemAtPath: target.path)
            try access.setOptimizationMark(mark, at: target)
        case "delete": try access.removeItem(at: target)
        case "symlink":
            try access.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        case "mark": try access.setExtendedAttribute(StoredOptimizationMark.attributeName, to: Data(), at: target)
        case "renameFailure": try access.removeItem(at: temporary)
        default: break
        }
        let survivingBytes = try? Data(contentsOf: target)
        if change == "unchanged" {
            try access.replaceMarkedItem(at: target, withItemAt: temporary, expected: expected)
            #expect(try Data(contentsOf: target) == bytes)
            #expect(!access.fileExists(at: temporary))
        } else {
            let error: FileAccessError = change == "renameFailure" ? .notFound : .destinationChanged
            #expect(throws: error) {
                try access.replaceMarkedItem(at: target, withItemAt: temporary, expected: expected)
            }
            #expect((try? Data(contentsOf: target)) == survivingBytes)
            if change == "symlink" {
                #expect(try access.attributes(of: target).kind == .symlink)
                #expect(try Data(contentsOf: other) == originalBytes)
            }
        }
    }
}
