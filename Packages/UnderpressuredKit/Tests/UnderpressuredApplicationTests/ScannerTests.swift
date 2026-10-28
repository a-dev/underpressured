import Foundation
import QueueTestSupport

import Testing
import UniformTypeIdentifiers

@testable import UnderpressuredCore
@testable import UnderpressuredApplication

@Suite struct ScannerTests {
    let fs = InMemoryFileAccess()
    let drop = URL(fileURLWithPath: "/Drop")

    func f(_ path: String) -> URL { URL(fileURLWithPath: "/Drop/" + path) }

    func scan(
        _ dropped: [URL]? = nil, export: URL? = nil, active: Set<String> = []
    ) -> ScanResult {
        Scanner(files: fs).scan(
            dropped ?? [drop], exportFolder: export,
            isActive: { active.contains($0.standardizedFileURL.path) })
    }

    func names(_ result: ScanResult) -> [String] {
        result.items.map { $0.source.path.replacingOccurrences(of: "/Drop/", with: "") }
    }

    @Test func cancellationStopsDirectoryTraversal() async {
        fs.addFile(f("a.jpg"), contentType: .jpeg)
        fs.addFile(f("b.jpg"), contentType: .jpeg)
        fs.addFile(f("nested/c.jpg"), contentType: .jpeg)
        let scanner = Scanner(files: fs)
        let root = drop
        let task = Task.detached {
            scanner.scan([root], isActive: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            })
        }
        let result = await task.value
        #expect(names(result) == ["a.jpg"])
    }

    @Test func recursion_spec7_2_findsNestedFiles() {
        fs.addFile(f("a.jpg"), contentType: .jpeg)
        fs.addFile(f("sub/deeper/b.png"), contentType: .png)
        let result = scan()
        #expect(names(result) == ["a.jpg", "sub/deeper/b.png"])
        #expect(result.items.allSatisfy { $0.droppedRoot == drop })
    }

    @Test func order_spec7_2_byNameThenDepthFirst() {
        fs.addFile(f("b.jpg"), contentType: .jpeg)
        fs.addFile(f("img10.jpg"), contentType: .jpeg)
        fs.addFile(f("img2.jpg"), contentType: .jpeg)
        fs.addFile(f("A.jpg"), contentType: .jpeg)
        fs.addFile(f("a2/x.jpg"), contentType: .jpeg)
        #expect(names(scan()) == ["A.jpg", "a2/x.jpg", "b.jpg", "img2.jpg", "img10.jpg"])
    }

    @Test func dropOrder_spec7_2_keptAcrossDroppedUrls() {
        fs.addFile(URL(fileURLWithPath: "/z.png"), contentType: .png)
        fs.addFile(f("a.jpg"), contentType: .jpeg)
        let result = scan([URL(fileURLWithPath: "/z.png"), drop])
        #expect(result.items.map(\.source.path) == ["/z.png", "/Drop/a.jpg"])
        #expect(result.items[0].droppedRoot == nil)
        #expect(result.items[1].droppedRoot == drop)
    }

    @Test func hiddenSkipped_spec7_2() {
        fs.addFile(f("ok.jpg"), contentType: .jpeg)
        fs.addFile(f(".hidden.jpg"), contentType: .jpeg, hidden: true)
        fs.fail(.permissionDenied, on: f(".hidden.jpg"), for: .read)
        fs.addDirectory(f(".cache"), hidden: true)
        fs.addFile(f(".cache/inside.jpg"), contentType: .jpeg)
        let result = scan()
        #expect(names(result) == ["ok.jpg"])
        #expect(result.ignoredCount == 0)
        #expect(result.failures.isEmpty)
    }

    @Test func packagesSkipped_spec7_2() {
        fs.addFile(f("ok.jpg"), contentType: .jpeg)
        fs.addDirectory(f("Photos.photoslibrary"), isPackage: true)
        fs.addFile(f("Photos.photoslibrary/original.jpg"), contentType: .jpeg)
        #expect(names(scan()) == ["ok.jpg"])
    }

    @Test func symlinksNotFollowed_spec7_2() {
        fs.addFile(f("real/pic.jpg"), contentType: .jpeg)
        fs.addSymlink(f("linkToFolder"), to: f("real"))
        fs.addSymlink(f("linkToFile.jpg"), to: f("real/pic.jpg"))
        let result = scan()
        #expect(names(result) == ["real/pic.jpg"])
        #expect(result.ignoredCount == 0)
    }

    @Test func exportFolderSkipped_spec7_2() {
        fs.addFile(f("ok.jpg"), contentType: .jpeg)
        fs.addFile(f("Export/out.jpg"), contentType: .jpeg)
        fs.addFile(f("Export/nested/out2.jpg"), contentType: .jpeg)
        let result = scan(export: f("Export/"))
        #expect(names(result) == ["ok.jpg"])
    }

    @Test func exportFolderComparedByStandardizedPath_spec7_2() {
        fs.addFile(f("Export/out.jpg"), contentType: .jpeg)
        let result = scan(export: URL(fileURLWithPath: "/Drop/x/../Export"))
        #expect(result.items.isEmpty)
    }

    @Test func acceptedFormatsByContentType_spec7_2() {
        let accepted: [UTType] = [
            .jpeg, .png, .heic, .heif, .webP, .tiff, UTType("public.avif") ?? UTType(importedAs: "public.avif"), UTType("public.jxl") ?? UTType(importedAs: "public.jxl"),
        ]
        for (i, type) in accepted.enumerated() {
            fs.addFile(f("\(i)"), contentType: type)  // no extension: type decides
        }
        let result = scan()
        #expect(result.items.count == accepted.count)
        #expect(result.items.allSatisfy { $0.state == .waiting })
    }

    @Test func extensionIgnored_spec7_2() {
        fs.addFile(f("photo.jpg"), contentType: .plainText)
        fs.addFile(f("notes.txt"), contentType: .png)
        let result = scan()
        #expect(names(result) == ["notes.txt"])
        #expect(result.ignoredCount == 1)
    }

    @Test func unsupportedGIF_spec7_2() {
        fs.addFile(f("a.gif"), contentType: .gif)
        #expect(scan().items.first?.state == .finished(.skipped(.unsupported(.gif), notes: [])))
    }

    @Test func unsupportedRAW_spec7_2() {
        fs.addFile(f("a.cr2"), contentType: UTType("com.canon.cr2-raw-image"))
        fs.addFile(f("b.dng"), contentType: UTType("com.adobe.raw-image"))
        let result = scan()
        #expect(result.items.count == 2)
        #expect(
            result.items.allSatisfy { $0.state == .finished(.skipped(.unsupported(.raw), notes: [])) })
    }

    @Test func unsupportedOtherImageType_spec7_2() {
        fs.addFile(f("a.bmp"), contentType: .bmp)
        fs.addFile(f("b.ico"), contentType: .ico)
        let result = scan()
        #expect(result.items.count == 2)
        #expect(
            result.items.allSatisfy {
                $0.state == .finished(.skipped(.unsupported(.otherType), notes: []))
            })
    }

    @Test func nonImagesCountedNotListed_spec7_2() {
        fs.addFile(f("ok.jpg"), contentType: .jpeg)
        fs.addFile(f("doc.pdf"), contentType: .pdf)
        fs.addFile(f("sub/notes.txt"), contentType: .plainText)
        fs.addFile(f("sub/mystery"), contentType: nil)
        let result = scan()
        #expect(names(result) == ["ok.jpg"])
        #expect(result.ignoredCount == 3)
    }

    @Test func nonImageDroppedDirectlyCounted_spec7_2() {
        fs.addFile(URL(fileURLWithPath: "/doc.pdf"), contentType: .pdf)
        let result = scan([URL(fileURLWithPath: "/doc.pdf")])
        #expect(result.items.isEmpty)
        #expect(result.ignoredCount == 1)
    }

    @Test func alreadyInQueue_spec7_2() {
        fs.addFile(f("a.jpg"), contentType: .jpeg)
        fs.addFile(f("b.jpg"), contentType: .jpeg)
        let result = scan(active: ["/Drop/a.jpg"])
        #expect(result.items.map(\.state) == [
            .finished(.skipped(.alreadyInQueue, notes: [])), .waiting,
        ])
    }

    @Test func looseFileHasNoRoot_spec7_2() {
        fs.addFile(f("a.jpg"), contentType: .jpeg)
        let result = scan([f("a.jpg")])
        #expect(result.items.count == 1)
        #expect(result.items[0].droppedRoot == nil)
        #expect(result.items[0].state == .waiting)
    }

    // Direct-drop choices (the scanner's reading of §7.2).

    @Test func droppedHiddenFileTaken_spec7_2() {
        fs.addFile(f(".secret.jpg"), contentType: .jpeg, hidden: true)
        #expect(scan([f(".secret.jpg")]).items.count == 1)
    }

    @Test func droppedHiddenFolderScanned_spec7_2() {
        fs.addDirectory(f(".stash"), hidden: true)
        fs.addFile(f(".stash/a.jpg"), contentType: .jpeg)
        fs.addFile(f(".stash/.b.jpg"), contentType: .jpeg, hidden: true)
        let result = scan([f(".stash")])
        #expect(result.items.map(\.source.lastPathComponent) == ["a.jpg"])
        #expect(result.items[0].droppedRoot == f(".stash"))
    }

    @Test func droppedSymlinkIgnored_spec7_2() {
        fs.addFile(f("real.jpg"), contentType: .jpeg)
        fs.addSymlink(f("link.jpg"), to: f("real.jpg"))
        let result = scan([f("link.jpg")])
        #expect(result.items.isEmpty)
        #expect(result.ignoredCount == 1)
    }

    @Test func droppedPackageIgnored_spec7_2() {
        fs.addDirectory(f("Lib.photoslibrary"), isPackage: true)
        fs.addFile(f("Lib.photoslibrary/a.jpg"), contentType: .jpeg)
        let result = scan([f("Lib.photoslibrary")])
        #expect(result.items.isEmpty)
        #expect(result.ignoredCount == 1)
    }

    @Test func droppedExportFolderIgnored_spec7_2() {
        fs.addFile(f("Export/a.jpg"), contentType: .jpeg)
        let result = scan([f("Export")], export: f("Export"))
        #expect(result.items.isEmpty)
    }

    @Test func missingPathReportedSeparately() {
        let result = scan([f("gone.jpg"), f("gone.jpg")])
        #expect(result.items.isEmpty)
        #expect(result.ignoredCount == 0)
        #expect(result.failures == [ScanFailure(url: f("gone.jpg"), reason: .fileNotFound)])
    }

    @Test func unreadableSubfolderSkipped_spec7_2() {
        fs.addFile(f("ok.jpg"), contentType: .jpeg)
        fs.addFile(f("locked/a.jpg"), contentType: .jpeg)
        fs.fail(.permissionDenied, on: f("locked"), for: .listDirectory)
        fs.addFile(f("unreadable.jpg"), contentType: .jpeg)
        fs.fail(.other("internal"), on: f("unreadable.jpg"), for: .read)
        let result = scan()
        #expect(names(result) == ["ok.jpg"])
        #expect(result.ignoredCount == 0)
        #expect(result.failures == [
            ScanFailure(url: f("locked"), reason: .noPermission),
            ScanFailure(url: f("unreadable.jpg"), reason: .fileIOFailed)
        ])
    }

    @Test func fileDroppedTwiceListedOnce_spec7_2() {
        fs.addFile(f("a.jpg"), contentType: .jpeg)
        let result = scan([f("a.jpg"), drop])
        #expect(result.items.count == 1)
        #expect(result.items[0].droppedRoot == nil)
    }

    @Test func feedsBatch_spec7_1() {
        fs.addFile(f("a.jpg"), contentType: .jpeg)
        fs.addFile(f("n.txt"), contentType: .plainText)
        let result = scan()
        let batch = Batch(
            activePreset: Preset.starters[0], outputFormat: .original,
            destination: .replaceOriginals(moveToTrash: true), items: result.items,
            ignoredCount: result.ignoredCount)
        #expect(batch.items.count == 1)
        #expect(batch.ignoredCount == 1)
    }
}
