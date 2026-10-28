import UnderpressuredApplication
import AppKit
import AppModel
import QuickLookUI
import SwiftUI
import Testing
import UnderpressuredCore
@testable import Underpressured

extension NativeAppTests {
@MainActor
@Suite(.serialized) struct ItemListFocusTests {
    private func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }

    private func model(root: URL = URL(filePath: "/tmp")) async throws -> AppModel {
        let model = AppModel(
            queue: Queue(parallelism: 1, pixelBudget: 1_000) { item, _, _, _ in
                item.source.lastPathComponent == "failed.jpg" ? .failed(.cantRead) :
                    .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: item.source)
            },
            intake: { urls, _, _ in ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: 0) },
            fileExists: { _ in true })
        await model.open([root.appending(path: "failed.jpg"), root.appending(path: "success.jpg")])
        for _ in 0..<100 where model.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isRunning)
        return model
    }

    @Test func launchFocusStaysInPresetBarInsteadOfTrash() async throws {
        let model = AppModel(queue: Queue(parallelism: 1, pixelBudget: 1_000) { _, _, _, _ in .failed(.cantRead) },
            intake: { _, _, _ in ScanResult(items: [], ignoredCount: 0) })
        let host = NSHostingView(rootView: MainWindow(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await settle()
        let responder = try #require(window.firstResponder as? NSView)
        // The preset bar is the only scroll view in an empty main window.
        #expect(responder.accessibilityParent() is NSScrollView)
    }

    @Test func removingFilterDoesNotTakeFocusFromAnotherControl() async throws {
        let model = try await model()
        model.toggleFilter(.failed)
        let host = NSHostingView(rootView: ItemListView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content
        host.frame = NSRect(x: 0, y: 40, width: 560, height: 320)
        content.addSubview(host)
        let button = NSButton(title: "Show all outcomes", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 160, height: 30)
        content.addSubview(button)
        window.makeKeyAndOrderFront(nil)
        try await settle()
        #expect(window.makeFirstResponder(button))
        #expect(window.firstResponder === button)
        model.toggleFilter(.failed)
        try await settle()
        #expect(model.rows.count == 2)
        #expect(window.firstResponder === button)
        host.removeFromSuperview()
        let replacement = NSHostingView(rootView: ItemListView(model: model))
        replacement.frame = host.frame
        content.addSubview(replacement)
        try await settle()
        #expect(window.firstResponder === button)
    }

    @Test func intakeDoesNotInterruptAnActiveTextEditor() async throws {
        let model = try await model()
        let host = NSHostingView(rootView: ItemListView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content
        host.frame = NSRect(x: 0, y: 40, width: 560, height: 320)
        content.addSubview(host)
        let field = NSTextField(string: "Editing preset name")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 30)
        content.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        try await settle()
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor())
        #expect(window.firstResponder === editor)
        await model.open([URL(filePath: "/tmp/new.jpg")])
        try await settle()
        #expect(model.rows.count == 3)
        #expect(window.firstResponder === editor)
        #expect(field.stringValue == "Editing preset name")
    }

    @Test func initialIntakeAllowsArrowNavigationWithoutClicking() async throws {
        let model = try await model()
        let host = NSHostingView(rootView: ItemListView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await settle()
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125))
        window.sendEvent(event)
        try await settle()
        #expect(model.selection.count == 1)
        let responder = window.firstResponder
        await model.open([URL(filePath: "/tmp/new.jpg")])
        try await settle()
        #expect(window.firstResponder === responder)
        #expect(model.selection.count == 1)
    }

    @Test func clickingARowTakesFocusSoSpaceOpensQuickLook() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        try data.write(to: directory.appending(path: "success.jpg"))
        let model = try await model(root: directory)
        let host = NSHostingView(rootView: MainWindow(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await settle()
        // Tab left keyboard focus on a preset badge.
        model.presetFocusID = model.presets.presets.first?.id
        try await settle()
        let presetResponder = window.firstResponder
        let panel = try #require(QLPreviewPanel.shared())
        #expect(!panel.isVisible)
        // A click selects through the List binding; synthetic mouse events don't reach its table here.
        model.selection = [model.rows[1].id]
        try await settle()
        #expect(window.firstResponder !== presetResponder)
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        window.sendEvent(space)
        try await settle()
        #expect(panel.isVisible)
        // Close it the way the user would so the shared panel is clean for the next test.
        window.sendEvent(space)
        for _ in 0..<100 where panel.isVisible { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!panel.isVisible)
    }

    @Test func spaceActivatesAFocusedBadgeAndReturnOpensItsEditor() async throws {
        let model = try await model()
        let host = NSHostingView(rootView: MainWindow(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await settle()
        let target = try #require(model.presets.presets.first { $0.id != model.presets.activeID }).id
        model.presetFocusID = target
        try await settle()
        func press(_ characters: String, keyCode: UInt16) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
            window.sendEvent(event)
        }
        try press(" ", keyCode: 49)
        try await settle()
        #expect(model.presets.activeID == target)
        #expect(model.editingPresetID == nil)
        try press("\r", keyCode: 36)
        try await settle()
        #expect(model.editingPresetID == target)
        model.closePresetEditor()
    }

    @Test func hidingTheSelectedRowClosesQuickLook() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        try data.write(to: directory.appending(path: "success.jpg"))
        let model = try await model(root: directory)
        let host = NSHostingView(rootView: ItemListView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await settle()
        let panel = try #require(QLPreviewPanel.shared())
        #expect(!panel.isVisible)
        model.selection = [model.rows[1].id]
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        window.sendEvent(space)
        try await settle()
        defer { panel.orderOut(nil) }
        #expect(panel.isVisible)
        let dismissalStart = ContinuousClock.now
        model.toggleFilter(.failed)
        try await settle()
        #expect(model.selection.isEmpty)
        for _ in 0..<100 where panel.isVisible { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!panel.isVisible)
        print("Quick Look filter dismissal elapsed: \(dismissalStart.duration(to: .now))")
    }
}

}
