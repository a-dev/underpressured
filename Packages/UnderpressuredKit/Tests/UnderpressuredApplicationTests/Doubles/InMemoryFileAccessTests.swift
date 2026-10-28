import UnderpressuredApplication
import Foundation
import QueueTestSupport

import Testing
@testable import UnderpressuredCore
import UniformTypeIdentifiers

private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

@Suite("InMemoryFileAccess")
struct InMemoryFileAccessTests {
    @Test func addFile_createsMissingFoldersAndStoresContents() throws {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/Photos/2024/cat.jpg"), data: Data([1, 2, 3]), contentType: .jpeg)

        #expect(fs.exists(url("/Photos")))
        #expect(fs.exists(url("/Photos/2024")))
        #expect(fs.data(at: url("/Photos/2024")) == nil)
        #expect(try fs.readData(at: url("/Photos/2024/cat.jpg")) == Data([1, 2, 3]))
        let attributes = try fs.attributes(of: url("/Photos/2024/cat.jpg"))
        #expect(attributes.kind == .file)
        #expect(attributes.size == 3)
        #expect(attributes.contentType == .accepted(.jpeg))
    }

    @Test func flags_hiddenAndPackageAreReported() throws {
        let fs = InMemoryFileAccess()
        fs.addDirectory(url("/Library/.cache"), hidden: true)
        fs.addDirectory(url("/Library/Photos.photoslibrary"), isPackage: true)
        fs.addFile(url("/Library/.DS_Store"), hidden: true)

        let cache = try fs.attributes(of: url("/Library/.cache"))
        #expect(cache.kind == .directory)
        #expect(cache.isHidden)
        #expect(!cache.isPackage)
        #expect(try fs.attributes(of: url("/Library/Photos.photoslibrary")).isPackage)
        #expect(try fs.attributes(of: url("/Library/.DS_Store")).isHidden)
    }

    @Test func contentsOfDirectory_listsOnlyDirectChildren() throws {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/A/one.jpg"))
        fs.addFile(url("/A/sub/two.jpg"))
        fs.addSymlink(url("/A/link"), to: url("/A/sub"))

        let children = try fs.contentsOfDirectory(at: url("/A")).map(\.path)
        #expect(Set(children) == ["/A/one.jpg", "/A/sub", "/A/link"])
        #expect(throws: FileAccessError.notFound) { try fs.contentsOfDirectory(at: url("/Missing")) }
    }

    @Test func symlink_isReportedAsLinkAndReadThrough() throws {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/t.txt"), data: Data("target".utf8))
        fs.addSymlink(url("/l.txt"), to: url("/t.txt"))

        #expect(try fs.attributes(of: url("/l.txt")).kind == .symlink)
        #expect(try fs.readData(at: url("/l.txt")) == Data("target".utf8))
    }

    @Test func caseInsensitiveByDefault_lookupFindsDifferentlySpelledName() throws {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/Pics/a.jpg"), data: Data([7]))

        #expect(fs.fileExists(at: url("/Pics/A.jpg")))
        #expect(try fs.isCaseSensitiveVolume(at: url("/Pics")) == false)

        fs.setCaseSensitive(true)
        #expect(fs.fileExists(at: url("/Pics/A.jpg")) == false)
        #expect(try fs.isCaseSensitiveVolume(at: url("/Pics")))
    }

    @Test func moveItem_movesSubtreeKeepingIdentity() throws {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/a/one.jpg"))
        fs.addFile(url("/a/sub/two.jpg"), data: Data([2]))
        let identity = try fs.attributes(of: url("/a/sub/two.jpg")).fileIdentity

        try fs.moveItem(at: url("/a"), to: url("/b"))

        #expect(fs.allPaths == ["/b", "/b/one.jpg", "/b/sub", "/b/sub/two.jpg"])
        #expect(fs.data(at: url("/b/sub/two.jpg")) == Data([2]))
        #expect(try fs.attributes(of: url("/b/sub/two.jpg")).fileIdentity == identity)
    }

    @Test func moveItem_failsWhenDestinationExistsOrParentIsMissing() {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/x.jpg"))
        fs.addFile(url("/y.jpg"))

        #expect(throws: FileAccessError.alreadyExists) {
            try fs.moveItem(at: url("/x.jpg"), to: url("/y.jpg"))
        }
        #expect(throws: FileAccessError.notFound) {
            try fs.moveItem(at: url("/x.jpg"), to: url("/nowhere/x.jpg"))
        }
        #expect(throws: FileAccessError.notFound) {
            try fs.moveItem(at: url("/gone.jpg"), to: url("/z.jpg"))
        }
    }

    @Test func moveItem_allowsCaseOnlyRenameOnCaseInsensitiveVolume() throws {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/p/a.jpg"))

        try fs.moveItem(at: url("/p/a.jpg"), to: url("/p/A.jpg"))

        #expect(fs.allPaths == ["/p", "/p/A.jpg"])
    }

    @Test func writeTemporaryFile_createsHiddenFileInTempFolder() throws {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/Pics/a.jpg"))
        fs.now = Date(timeIntervalSince1970: 500)

        let temp = try fs.writeTemporaryFile(Data([9, 9]), near: url("/Pics/a.jpg"))

        #expect(temp.path.hasPrefix("/.tmp/"))
        #expect(fs.data(at: temp) == Data([9, 9]))
        let attributes = try fs.attributes(of: temp)
        #expect(attributes.isHidden)
        #expect(attributes.modificationDate == Date(timeIntervalSince1970: 500))
    }

    @Test func createDirectory_requiresParentAndRejectsExistingItem() throws {
        let fs = InMemoryFileAccess()

        #expect(throws: FileAccessError.notFound) { try fs.createDirectory(at: url("/a/b")) }
        try fs.createDirectory(at: url("/a"))
        try fs.createDirectory(at: url("/a/b"))
        #expect(throws: FileAccessError.alreadyExists) { try fs.createDirectory(at: url("/a/b")) }
        #expect(try fs.attributes(of: url("/a/b")).kind == .directory)
    }

    @Test func copyItem_copiesContentsWithNewIdentityAndKeepsSource() throws {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/a.jpg"), data: Data([4]))
        fs.addFile(url("/taken.jpg"))
        let sourceIdentity = try fs.attributes(of: url("/a.jpg")).fileIdentity

        try fs.copyItem(at: url("/a.jpg"), to: url("/b.jpg"))

        #expect(fs.data(at: url("/a.jpg")) == Data([4]))
        #expect(fs.data(at: url("/b.jpg")) == Data([4]))
        #expect(try fs.attributes(of: url("/b.jpg")).fileIdentity != sourceIdentity)
        #expect(throws: FileAccessError.alreadyExists) {
            try fs.copyItem(at: url("/a.jpg"), to: url("/taken.jpg"))
        }
    }

    @Test func removeItem_removesFolderWithItsContents() throws {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/d/sub/x.jpg"))

        try fs.removeItem(at: url("/d"))

        #expect(fs.allPaths.isEmpty)
        #expect(throws: FileAccessError.notFound) { try fs.removeItem(at: url("/d")) }
    }

    @Test func trashItem_recordsTheItemAndRemovesIt() throws {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/Pics/a.jpg"))
        #expect(fs.hasTrash(forItemAt: url("/Pics/a.jpg")))

        try fs.trashItem(at: url("/Pics/a.jpg"))

        #expect(fs.trashed == [url("/Pics/a.jpg")])
        #expect(fs.exists(url("/Pics/a.jpg")) == false)
    }

    @Test func trashItem_failsWithoutTrashAndKeepsItem() {
        let fs = InMemoryFileAccess()
        fs.setHasTrash(false)
        fs.addFile(url("/a.jpg"))

        #expect(fs.hasTrash(forItemAt: url("/a.jpg")) == false)
        #expect(throws: FileAccessError.noTrash) { try fs.trashItem(at: url("/a.jpg")) }
        #expect(fs.exists(url("/a.jpg")))
        #expect(fs.trashed.isEmpty)
    }

    @Test func copyDatesAndTags_copiesDatesAndTags() throws {
        let fs = InMemoryFileAccess()
        let created = Date(timeIntervalSince1970: 1_000)
        let modified = Date(timeIntervalSince1970: 2_000)
        fs.addFile(url("/src.jpg"), modificationDate: modified, creationDate: created)
        fs.setTags(["Red", "Work"], at: url("/src.jpg"))
        fs.addFile(url("/dst.jpg"))

        try fs.copyDatesAndTags(from: url("/src.jpg"), to: url("/dst.jpg"))

        let copy = try fs.attributes(of: url("/dst.jpg"))
        #expect(copy.creationDate == created)
        #expect(copy.modificationDate == modified)
        #expect(fs.tags(at: url("/dst.jpg")) == ["Red", "Work"])
    }

    @Test func extendedAttributes_roundTripAndReadNilWhenAbsent() throws {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/a.jpg"))

        try fs.setExtendedAttribute("com.apple.quarantine", to: Data("q".utf8), at: url("/a.jpg"))

        #expect(try fs.extendedAttribute("com.apple.quarantine", at: url("/a.jpg")) == Data("q".utf8))
        #expect(try fs.extendedAttribute("com.apple.other", at: url("/a.jpg")) == nil)
        #expect(throws: FileAccessError.notFound) {
            try fs.setExtendedAttribute("x", to: Data(), at: url("/missing"))
        }
    }

    @Test func replaceItem_putsReplacementAtOriginalPathAndConsumesIt() throws {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/img.jpg"), data: Data("old".utf8))
        fs.addFile(url("/tmp/new.jpg"), data: Data("new".utf8))

        try fs.replaceItem(at: url("/img.jpg"), withItemAt: url("/tmp/new.jpg"))

        #expect(fs.data(at: url("/img.jpg")) == Data("new".utf8))
        #expect(fs.exists(url("/tmp/new.jpg")) == false)
    }

    @Test func writes_stampModificationDatesFromTheClock() throws {
        let fs = InMemoryFileAccess()
        fs.now = Date(timeIntervalSince1970: 100)
        fs.addFile(url("/a.jpg"))
        let before = try fs.attributes(of: url("/a.jpg")).modificationDate

        fs.now = Date(timeIntervalSince1970: 200)
        fs.addFile(url("/a.jpg"), data: Data([1]))
        let after = try fs.attributes(of: url("/a.jpg")).modificationDate

        #expect(before == Date(timeIntervalSince1970: 100))
        #expect(after == Date(timeIntervalSince1970: 200))
    }

    @Test func fileIdentity_isUniquePerCreatedItem() throws {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/a.jpg"))
        fs.addFile(url("/b.jpg"))

        let a = try fs.attributes(of: url("/a.jpg")).fileIdentity
        let b = try fs.attributes(of: url("/b.jpg")).fileIdentity

        #expect(a != b)
        #expect(a > 0 && b > 0)
    }

    @Test func fail_appliesOnlyToTheNamedURLAndOperation() throws {
        let fs = InMemoryFileAccess()
        fs.addFile(url("/locked.jpg"), data: Data([5]))
        fs.addFile(url("/open.jpg"))
        fs.fail(.permissionDenied, on: url("/locked.jpg"), for: .write)

        #expect(throws: FileAccessError.permissionDenied) {
            try fs.setExtendedAttribute("x", to: Data(), at: url("/locked.jpg"))
        }
        #expect(throws: FileAccessError.permissionDenied) {
            try fs.writeTemporaryFile(Data(), near: url("/locked.jpg"))
        }
        #expect(try fs.readData(at: url("/locked.jpg")) == Data([5]))
        _ = try fs.writeTemporaryFile(Data(), near: url("/open.jpg"))
    }
}
