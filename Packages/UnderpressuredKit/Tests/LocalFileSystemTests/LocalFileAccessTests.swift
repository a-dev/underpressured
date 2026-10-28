import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UnderpressuredCore
import UniformTypeIdentifiers

@testable import LocalFileSystem

/// A real temporary folder per test, removed when the suite instance goes away.
///
/// Layout:
///     a.png  b.jpg  notes.txt  .hidden  Thing.app/Contents/Info.plist
///     link-to-file -> a.png   broken-link -> missing
///     sub/d.png   Export/c.png
final class LocalFileAccessTests {
    let root: URL
    let access = LocalFileAccess()

    init() throws {
        let volumeRoot = ProcessInfo.processInfo.environment["UP_TEST_VOLUME_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        root = volumeRoot
            .appendingPathComponent("up-LocalFileAccessTests-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.png().write(to: root.appendingPathComponent("a.png"))
        try Self.jpeg().write(to: root.appendingPathComponent("b.jpg"))
        try Data("hello".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("secret".utf8).write(to: root.appendingPathComponent(".hidden"))
        let contents = root.appendingPathComponent("Thing.app/Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.thing", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("link-to-file"),
            withDestinationURL: root.appendingPathComponent("a.png"))
        try fm.createSymbolicLink(
            atPath: root.appendingPathComponent("broken-link").path, withDestinationPath: "missing")
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Self.png().write(to: root.appendingPathComponent("sub/d.png"))
        try fm.createDirectory(at: root.appendingPathComponent("Export"), withIntermediateDirectories: true)
        try Self.png().write(to: root.appendingPathComponent("Export/c.png"))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    @Test func scannerDeduplicatesHardLinksByDeviceAndInode() throws {
        let original = url("a.png")
        let alias = url("alias.png")
        try FileManager.default.linkItem(at: original, to: alias)
        let attributes = try access.attributes(of: original)
        #expect(attributes.volumeIdentity != 0)
        #expect(attributes.fileIdentity == (try access.attributes(of: alias)).fileIdentity)
        let scan = Scanner(files: access).scan([original, alias])
        #expect(scan.items.map(\.source) == [original])
    }

    // MARK: Real image bytes

    private static func image() -> CGImage {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }

    private static func encoded(_ type: UTType) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image(), nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func png() -> Data { encoded(.png) }
    private static func jpeg() -> Data { encoded(.jpeg) }

    // MARK: Listing and existence

    @Test func listing_returnsDirectChildrenWithoutFollowingSymlinks() throws {
        let names = try access.contentsOfDirectory(at: root).map(\.lastPathComponent).sorted()
        #expect(
            names == [
                ".hidden", "Export", "Thing.app", "a.png", "b.jpg", "broken-link", "link-to-file",
                "notes.txt", "sub",
            ])
    }

    @Test func fileExists_trueForFilesAndBrokenSymlinks_falseForMissing() {
        #expect(access.fileExists(at: url("a.png")))
        #expect(access.fileExists(at: url("sub")))
        #expect(access.fileExists(at: url("broken-link")))
        #expect(!access.fileExists(at: url("missing")))
    }

    @Test func missingItem_throwsNotFound() {
        #expect(throws: FileAccessError.notFound) { try access.attributes(of: url("missing")) }
        #expect(throws: FileAccessError.notFound) { try access.readData(at: url("missing")) }
        #expect(throws: FileAccessError.notFound) { try access.contentsOfDirectory(at: url("missing")) }
    }

    @Test func readData_returnsFileBytes() throws {
        #expect(try access.readData(at: url("notes.txt")) == Data("hello".utf8))
    }

    // MARK: Attributes

    @Test func attributes_kindForFileFolderAndSymlinks() throws {
        #expect(try access.attributes(of: url("a.png")).kind == .file)
        #expect(try access.attributes(of: url("sub")).kind == .directory)
        #expect(try access.attributes(of: url("link-to-file")).kind == .symlink)
        #expect(try access.attributes(of: url("broken-link")).kind == .symlink)
    }

    @Test func attributes_hiddenAndPackageFlags() throws {
        #expect(try access.attributes(of: url(".hidden")).isHidden)
        #expect(try !access.attributes(of: url("a.png")).isHidden)
        let package = try access.attributes(of: url("Thing.app"))
        #expect(package.kind == .directory)
        #expect(package.isPackage)
        #expect(try !access.attributes(of: url("sub")).isPackage)
    }

    @Test func attributes_contentTypeFromContent() throws {
        #expect(try access.attributes(of: url("a.png")).contentType == .accepted(.png))
        #expect(try access.attributes(of: url("b.jpg")).contentType == .accepted(.jpeg))
        #expect(try access.attributes(of: url("notes.txt")).contentType == .notAnImage)
        #expect(try access.attributes(of: url("sub")).contentType == .notAnImage)
        #expect(try access.attributes(of: url("link-to-file")).contentType == .notAnImage)
    }

    @Test func attributes_sizeAndDates() throws {
        let attributes = try access.attributes(of: url("a.png"))
        #expect(attributes.size == Int64(Self.png().count))
        let now = Date()
        #expect(abs(attributes.creationDate.timeIntervalSince(now)) < 60)
        #expect(abs(attributes.modificationDate.timeIntervalSince(now)) < 60)
        #expect(try access.attributes(of: url("notes.txt")).size == 5)
    }

    @Test func attributes_symlinkDescribesTheLinkNotTheTarget() throws {
        let link = try access.attributes(of: url("link-to-file"))
        let target = try access.attributes(of: url("a.png"))
        #expect(link.fileIdentity != target.fileIdentity)
        #expect(link.size == Int64(url("a.png").path.utf8.count))  // a link's size is its target path
    }

    @Test func attributes_fileIdentityIsStableAndDistinct() throws {
        let first = try access.attributes(of: url("a.png")).fileIdentity
        let second = try access.attributes(of: url("a.png")).fileIdentity
        #expect(first != 0)
        #expect(first == second)
        #expect(try access.attributes(of: url("b.jpg")).fileIdentity != first)
    }

    // MARK: Volume and extended attributes

    @Test func volumeCaseSensitivity_matchesURLResourceValue() throws {
        let expected = try #require(
            root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                .volumeSupportsCaseSensitiveNames as Bool?)
        #expect(try access.isCaseSensitiveVolume(at: root) == expected)
    }

    @Test func extendedAttribute_roundTripAndMissing() throws {
        let file = url("a.png")
        let name = "com.example.underpressured.test"
        #expect(try access.extendedAttribute(name, at: file) == nil)
        let value = Data([0, 1, 2, 255, 7])
        try access.setExtendedAttribute(name, to: value, at: file)
        #expect(try access.extendedAttribute(name, at: file) == value)
        try access.setExtendedAttribute(name, to: Data(), at: file)
        #expect(try access.extendedAttribute(name, at: file) == Data())
    }

    @Test func extendedAttribute_onMissingFile_throwsNotFound() {
        #expect(throws: FileAccessError.notFound) {
            try access.extendedAttribute("com.example.x", at: url("missing"))
        }
    }

    // MARK: Through the Core scanner

    @Test func scan_spec7_2_realFolder() throws {
        let result = Scanner(files: access).scan([root], exportFolder: url("Export"))
        let sources = result.items.map { $0.source.lastPathComponent }
        // Images in name order, folders depth-first; hidden file, package, symlinks and the
        // nested Export folder are left out.
        #expect(sources == ["a.png", "b.jpg", "d.png"])
        #expect(result.items.allSatisfy { $0.state == .waiting })
        #expect(result.items.allSatisfy { $0.droppedRoot == root })
        // Only notes.txt is a non-image that was looked at.
        #expect(result.ignoredCount == 1)
    }

    @Test func scan_spec7_2_withoutExportFolder_includesIt() throws {
        let result = Scanner(files: access).scan([root])
        #expect(result.items.map { $0.source.lastPathComponent } == ["a.png", "b.jpg", "c.png", "d.png"])
    }

    @Test func scan_directDropOfSymlinkAndPackage_isIgnored() throws {
        let result = Scanner(files: access).scan(
            [url("link-to-file"), url("broken-link"), url("Thing.app")])
        #expect(result.items.isEmpty)
        #expect(result.ignoredCount == 3)
    }
}
