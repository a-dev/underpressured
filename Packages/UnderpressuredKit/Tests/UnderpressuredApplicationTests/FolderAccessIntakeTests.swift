import Foundation
import QueueTestSupport
import Testing
import UniformTypeIdentifiers

@testable import UnderpressuredApplication
import UnderpressuredCore

/// Folders are writable when granted. The log interleaves requests with Batch admissions.
@MainActor
private final class RecordingFolderAccess: FolderAccess {
    var writable: Set<String> = []
    var grants = true
    var requests: [URL] = []
    var purposes: [FolderAccessPurpose] = []
    var onRequest: (URL) async -> Void = { _ in }
    var log: [String] = []

    func canCreateFiles(in folder: URL) -> Bool { writable.contains(folder.path) }

    func requestAccess(to folder: URL, for purpose: FolderAccessPurpose) async {
        requests.append(folder)
        purposes.append(purpose)
        log.append("request \(folder.path)")
        await onRequest(folder)
        if grants { writable.insert(folder.path) }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FolderAccessIntakeTests {
    let files = InMemoryFileAccess()

    private func session(_ access: RecordingFolderAccess) -> ProcessingSession {
        let files = files
        let queue = Queue(parallelism: 1) { item, _, _, _ in
            .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: item.source)
        }
        let session = ProcessingSession(
            queue: queue,
            intake: { urls, export, isActive in Scanner(files: files).scan(urls, exportFolder: export, isActive: isActive) },
            folderAccess: access)
        session.onEvent = { event in
            switch event {
            case .queue(.batchAdded(let batch)):
                access.log.append("admitted \(batch.items.map(\.source.lastPathComponent).joined(separator: ","))")
            case .exportFolderGranted:
                access.log.append("granted")
            default: break
            }
        }
        return session
    }

    private func open(
        _ urls: [URL], _ access: RecordingFolderAccess, outputFormat: OutputFormat = .jpeg,
        destination: Destination = .replaceOriginals(moveToTrash: false)
    ) async {
        let session = session(access)
        await session.open(urls) {
            ProcessingSession.Capture(
                preset: Preset(name: "Web", quality: 80, lossless: false, resizeRule: .none, keepMetadata: false),
                outputFormat: outputFormat, destination: destination)
        }
        await session.untilIdle()
    }

    @Test func asksForTheParentFolderOfAConvertedLooseFileBeforeAdmission() async {
        files.addFile(URL(filePath: "/Photos/a.png"), contentType: .png)
        let access = RecordingFolderAccess()

        await open([URL(filePath: "/Photos/a.png")], access)

        #expect(access.log == ["request /Photos", "admitted a.png"])
        #expect(access.purposes == [.siblingOutputs])
    }

    @Test func asksOncePerDistinctFolderInDropOrder() async {
        for path in ["/B/1.png", "/A/2.png", "/B/3.png"] { files.addFile(URL(filePath: path), contentType: .png) }
        let access = RecordingFolderAccess()

        await open(["/B/1.png", "/A/2.png", "/B/3.png"].map { URL(filePath: $0) }, access)

        #expect(access.requests.map(\.path) == ["/B", "/A"])
    }

    @Test func refusedAccessStillAdmitsTheItems() async {
        files.addFile(URL(filePath: "/Photos/a.png"), contentType: .png)
        let access = RecordingFolderAccess()
        access.grants = false

        await open([URL(filePath: "/Photos/a.png")], access)

        #expect(access.log == ["request /Photos", "admitted a.png"])
    }

    @Test func writableFolderIsNotRequested() async {
        files.addFile(URL(filePath: "/Photos/a.png"), contentType: .png)
        let access = RecordingFolderAccess()
        access.writable = ["/Photos"]

        await open([URL(filePath: "/Photos/a.png")], access)

        #expect(access.requests.isEmpty)
    }

    @Test func noRequestWhenTheResultTakesTheSourcesPlace() async {
        files.addFile(URL(filePath: "/Photos/a.jpg"), contentType: .jpeg)
        files.addFile(URL(filePath: "/Photos/b.png"), contentType: .png)
        let access = RecordingFolderAccess()

        await open([URL(filePath: "/Photos/a.jpg")], access, outputFormat: .jpeg)
        await open([URL(filePath: "/Photos/b.png")], access, outputFormat: .original)

        #expect(access.requests.isEmpty)
    }

    @Test func noRequestForExportCopiesToAWritableFolder() async {
        files.addFile(URL(filePath: "/Photos/a.png"), contentType: .png)
        files.addDirectory(URL(filePath: "/Export"))
        let access = RecordingFolderAccess()
        access.writable = ["/Export"]

        await open([URL(filePath: "/Photos/a.png")], access, destination: .exportFolder(URL(filePath: "/Export")))

        #expect(access.requests.isEmpty)
    }

    @Test func asksForAnUnwritableExportFolderBeforeAdmissionAndReportsTheGrant() async {
        files.addFile(URL(filePath: "/Photos/a.png"), contentType: .png)
        files.addDirectory(URL(filePath: "/Export"))
        let access = RecordingFolderAccess()

        await open([URL(filePath: "/Photos/a.png")], access, destination: .exportFolder(URL(filePath: "/Export")))

        #expect(access.log == ["request /Export", "granted", "admitted a.png"])
        #expect(access.purposes == [.exportFolder])
    }

    @Test func refusedExportFolderStillAdmitsTheItemsWithoutAGrant() async {
        files.addFile(URL(filePath: "/Photos/a.png"), contentType: .png)
        files.addDirectory(URL(filePath: "/Export"))
        let access = RecordingFolderAccess()
        access.grants = false

        await open([URL(filePath: "/Photos/a.png")], access, destination: .exportFolder(URL(filePath: "/Export")))

        #expect(access.log == ["request /Export", "admitted a.png"])
    }

    @Test func noRequestForFilesInADroppedFolder() async {
        files.addFile(URL(filePath: "/Photos/Trip/a.png"), contentType: .png)
        let access = RecordingFolderAccess()

        await open([URL(filePath: "/Photos")], access)

        #expect(access.requests.isEmpty)
    }

    @Test func noRequestForItemsTheScanAlreadyDecided() async {
        files.addFile(URL(filePath: "/Photos/a.gif"), contentType: .gif)
        files.addFile(URL(filePath: "/Photos/b.txt"), contentType: .plainText)
        let access = RecordingFolderAccess()

        await open([URL(filePath: "/Photos/a.gif"), URL(filePath: "/Photos/b.txt")], access)

        #expect(access.requests.isEmpty)
    }

    @Test func cancellingDuringTheRequestDiscardsTheBatch() async {
        files.addFile(URL(filePath: "/Photos/a.png"), contentType: .png)
        let access = RecordingFolderAccess()
        let session = session(access)
        access.onRequest = { _ in await session.cancel() }

        await session.open([URL(filePath: "/Photos/a.png")]) {
            ProcessingSession.Capture(
                preset: Preset(name: "Web", quality: 80, lossless: false, resizeRule: .none, keepMetadata: false),
                outputFormat: .jpeg, destination: .replaceOriginals(moveToTrash: false))
        }
        await session.untilIdle()

        #expect(access.log == ["request /Photos"])
        #expect(!session.activity.isRunning)
    }
}
