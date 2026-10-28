import Foundation
import QueueTestSupport

import Testing

@testable import UnderpressuredCore
@testable import UnderpressuredApplication

struct OutputPathPlannerTests {
    let fs = InMemoryFileAccess()
    let export = URL(filePath: "/Export", directoryHint: .isDirectory)
    let drop = URL(filePath: "/Users/me/Trip", directoryHint: .isDirectory)

    init() {
        fs.addDirectory(export)
        fs.addDirectory(drop)
    }

    private func planner() -> OutputPathPlanner { OutputPathPlanner(fileAccess: fs) }

    private func url(_ path: String) -> URL { URL(filePath: path) }

    private func exportPlan(
        _ planner: inout OutputPathPlanner, _ source: String, root: URL?, name: String
    ) throws -> OutputPlan {
        try planner.plan(
            source: url(source), droppedRoot: root, outputFileName: name, sameFormat: true,
            destination: .exportFolder(export))
    }

    /// Gives `file` a mark that matches its current size and date, as the writer would.
    private func mark(_ file: URL) throws {
        let attributes = try fs.attributes(of: file)
        let mark = OptimizationMark(
            settings: EffectiveSettings(quality: 80, lossless: false, resizeRule: .none, keepMetadata: false),
            outputFormat: .jpeg, size: attributes.size, modificationDate: attributes.modificationDate)
        try fs.setOptimizationMark(mark, at: file)
    }

    @Test func mirrorsDroppedFolder_spec6_2() throws {
        var p = planner()
        fs.addFile(url("/Users/me/Trip/Day 1/a.jpg"))
        let plan = try exportPlan(&p, "/Users/me/Trip/Day 1/a.jpg", root: drop, name: "a.jpg")
        #expect(plan.path.path == "/Export/Trip/Day 1/a.jpg")
        #expect(plan.kind == .newFile)
    }

    @Test func looseFileGoesToExportRoot_spec6_2() throws {
        var p = planner()
        let plan = try exportPlan(&p, "/Users/me/Desktop/a.png", root: nil, name: "a.png")
        #expect(plan.path.path == "/Export/a.png")
        #expect(plan.foldersToCreate.isEmpty)
    }

    @Test func missingFoldersArePlannedParentsFirst_spec6_2() throws {
        var p = planner()
        let plan = try exportPlan(&p, "/Users/me/Trip/Day 1/Beach/a.jpg", root: drop, name: "a.jpg")
        #expect(plan.foldersToCreate.map(\.path) == ["/Export/Trip", "/Export/Trip/Day 1", "/Export/Trip/Day 1/Beach"])
        #expect(!fs.exists(url("/Export/Trip")), "planning does no I/O")
    }

    /// Items run in parallel, so each must create the folders it needs (6.5 soak finding).
    @Test func missingFolderIsListedForEveryItem_spec6_2() throws {
        var p = planner()
        let first = try exportPlan(&p, "/Users/me/Trip/a.jpg", root: drop, name: "a.jpg")
        let second = try exportPlan(&p, "/Users/me/Trip/b.jpg", root: drop, name: "b.jpg")
        #expect(second.foldersToCreate == first.foldersToCreate)
        #expect(!second.foldersToCreate.isEmpty)
    }

    @Test func existingFoldersAreNotPlanned_spec6_2() throws {
        var p = planner()
        fs.addDirectory(url("/Export/Trip"))
        let plan = try exportPlan(&p, "/Users/me/Trip/Day 1/a.jpg", root: drop, name: "a.jpg")
        #expect(plan.foldersToCreate.map(\.path) == ["/Export/Trip/Day 1"])
    }

    @Test func nameClashNumbersBeforeExtension_spec6_3() throws {
        var p = planner()
        fs.addFile(url("/Export/a.jpg"))
        fs.addFile(url("/Export/a-2.jpg"))
        let plan = try exportPlan(&p, "/in/a.jpg", root: nil, name: "a.jpg")
        #expect(plan.path.path == "/Export/a-3.jpg")
    }

    @Test func numberingWithoutExtension_spec6_3() {
        #expect(OutputPathPlanner.numbered("README", 2) == "README-2")
        #expect(OutputPathPlanner.numbered("a.b.jpg", 2) == "a.b-2.jpg")
        #expect(OutputPathPlanner.numbered(".hidden", 2) == ".hidden-2")
    }

    @Test func clashIgnoresCaseOnCaseInsensitiveVolume_spec6_3() throws {
        var p = planner()
        fs.addFile(url("/Export/A.JPG"))
        let plan = try exportPlan(&p, "/in/a.jpg", root: nil, name: "a.jpg")
        #expect(plan.path.path == "/Export/a-2.jpg")
    }

    @Test func clashRespectsCaseOnCaseSensitiveVolume_spec6_3() throws {
        fs.setCaseSensitive(true)
        var p = planner()
        fs.addFile(url("/Export/A.JPG"))
        let plan = try exportPlan(&p, "/in/a.jpg", root: nil, name: "a.jpg")
        #expect(plan.path.path == "/Export/a.jpg")
    }

    @Test func twoItemsInOneRunGetDifferentPaths_spec6_3() throws {
        var p = planner()
        let first = try exportPlan(&p, "/x/a.jpg", root: nil, name: "a.jpg")
        let second = try exportPlan(&p, "/y/A.jpg", root: nil, name: "A.jpg")
        #expect(first.path.path == "/Export/a.jpg")
        #expect(second.path.path == "/Export/A-2.jpg")
    }

    @Test func markedFileInExportFolderIsOverwritten_spec6_3() throws {
        var p = planner()
        let existing = url("/Export/a.jpg")
        fs.addFile(existing, data: Data([1, 2, 3]))
        try mark(existing)
        let plan = try exportPlan(&p, "/in/a.jpg", root: nil, name: "a.jpg")
        #expect(plan.path.path == "/Export/a.jpg")
        guard case .overwriteMarked(let expected) = plan.kind else {
            Issue.record("Expected a marked overwrite plan")
            return
        }
        #expect(expected.size == 3)
    }

    @Test func markedFileIsOverwrittenOnlyOncePerRun_spec6_3() throws {
        var p = planner()
        let existing = url("/Export/a.jpg")
        fs.addFile(existing, data: Data([1, 2, 3]))
        try mark(existing)
        _ = try exportPlan(&p, "/x/a.jpg", root: nil, name: "a.jpg")
        let second = try exportPlan(&p, "/y/a.jpg", root: nil, name: "a.jpg")
        #expect(second.path.path == "/Export/a-2.jpg")
        #expect(second.kind == .newFile)
    }

    @Test func fileEditedAfterMarkingIsNumbered_spec6_3() throws {
        var p = planner()
        let existing = url("/Export/a.jpg")
        fs.addFile(existing, data: Data([1, 2, 3]))
        try mark(existing)
        fs.addFile(existing, data: Data([1, 2, 3, 4]))
        let plan = try exportPlan(&p, "/in/a.jpg", root: nil, name: "a.jpg")
        #expect(plan.path.path == "/Export/a-2.jpg")
    }

    @Test func replaceSameFormatTakesSourcePlace_spec6_1() throws {
        var p = planner()
        fs.addFile(url("/in/a.jpg"))
        let plan = try p.plan(
            source: url("/in/a.jpg"), droppedRoot: nil, outputFileName: "a.jpg", sameFormat: true,
            destination: .replaceOriginals(moveToTrash: true))
        #expect(plan.path.path == "/in/a.jpg")
        #expect(plan.kind == .replaceSource)
        #expect(plan.foldersToCreate.isEmpty)
    }

    @Test func replaceConversionClashIsNumbered_spec6_1() throws {
        var p = planner()
        fs.addFile(url("/in/a.png"))
        fs.addFile(url("/in/a.jpg"))
        let plan = try p.plan(
            source: url("/in/a.png"), droppedRoot: nil, outputFileName: "a.jpg", sameFormat: false,
            destination: .replaceOriginals(moveToTrash: true))
        #expect(plan.path.path == "/in/a-2.jpg")
        #expect(plan.kind == .newFile)
    }

    @Test func replaceConversionNeverOverwritesMarkedFile_spec6_3() throws {
        var p = planner()
        fs.addFile(url("/in/a.png"))
        let existing = url("/in/a.jpg")
        fs.addFile(existing, data: Data([1]))
        try mark(existing)
        let plan = try p.plan(
            source: url("/in/a.png"), droppedRoot: nil, outputFileName: "a.jpg", sameFormat: false,
            destination: .replaceOriginals(moveToTrash: true))
        #expect(plan.path.path == "/in/a-2.jpg")
    }

    @Test func replacedSourceIsReservedForLaterConversion_spec6_3() throws {
        var p = planner()
        fs.addFile(url("/in/a.jpg"))
        fs.addFile(url("/in/a.png"))
        _ = try p.plan(
            source: url("/in/a.jpg"), droppedRoot: nil, outputFileName: "a.jpg", sameFormat: true,
            destination: .replaceOriginals(moveToTrash: true))
        let conversion = try p.plan(
            source: url("/in/a.png"), droppedRoot: nil, outputFileName: "a.jpg", sameFormat: false,
            destination: .replaceOriginals(moveToTrash: true))
        #expect(conversion.path.path == "/in/a-2.jpg")
    }
}
