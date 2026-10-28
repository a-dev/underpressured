import UnderpressuredApplication
import AppKit
import AppModel
import UnderpressuredCore
import Testing
import SwiftUI
@testable import Underpressured

extension NativeAppTests {
@MainActor
@Suite(.serialized) struct ConstrainedLayoutTests {
    private func crowdedModel() -> AppModel {
        let model = AppModel(
            queue: Queue(parallelism: 1, pixelBudget: 1_000) { _, _, _, _ in
                .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: URL(filePath: "/tmp/a5-unused"))
            },
            intake: { _, _, _ in ScanResult(items: [], ignoredCount: 0) })
        while model.canAddPreset { model.addPreset() }
        model.closePresetEditor()
        for (index, preset) in model.presets.presets.enumerated() {
            model.setPresetName(preset.id, String(repeating: index.isMultiple(of: 2) ? "界" : "W", count: Preset.maxNameLength))
        }
        return model
    }

    @Test func twentyWidePresetsLeaveRoomForTheFileListAtMinimumWidth() {
        let model = crowdedModel()
        let host = NSHostingView(rootView: HeaderView(model: model).frame(width: 560))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height <= 112)
        #expect(model.presets.presets.count == 20)
    }

    @Test func shortPresetListKeepsItsNaturalHeight() {
        let model = crowdedModel()
        for preset in model.presets.presets.dropFirst() { model.deletePreset(preset.id) }
        let host = NSHostingView(rootView: HeaderView(model: model).frame(width: 560))
        #expect(host.fittingSize.height < 60)
    }

    @Test func cancellingDestinationPickerPreservesEffectiveModeAndTrash() {
        let model = crowdedModel()
        model.setMoveToTrash(true)
        var requests = 0
        let controls = DestinationControls(model: model, selectFolder: { requests += 1; return nil })
        let original = model.destination
        controls.chooseMode(.exportFolder)
        #expect(requests == 1)
        #expect(model.destination == original)
        model.chooseExportFolder(FileManager.default.temporaryDirectory)
        let exported = model.destination
        controls.pickFolder()
        #expect(requests == 2)
        #expect(model.destination == exported)
        controls.chooseMode(.replaceOriginals)
        #expect(model.showsMoveToTrash)
        #expect(model.destination.moveToTrash)
        controls.chooseMode(.exportFolder)
        #expect(requests == 2)
        #expect(model.destination == exported)
        model.forgetExportFolder()
        #expect(model.destination == original)
    }

    @Test func replacementControlsAndFullWindowFitMinimumSize() {
        let model = crowdedModel()
        model.setMoveToTrash(true)
        let host = NSHostingView(rootView: MainWindow(model: model))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.setContentSize(NSSize(width: 560, height: 360))
        host.layoutSubtreeIfNeeded()
        #expect(host.bounds.size == NSSize(width: 560, height: 360))
        #expect(host.fittingSize.width <= 560)
    }

    @Test func destinationModesManualReviewCapturesAtMinimumSize() async throws {
        let model = crowdedModel()
        model.setMoveToTrash(true)
        for mode in ["replace", "export"] {
            if mode == "export" {
                model.chooseExportFolder(URL(filePath: "/tmp/An exceptionally long nested export destination/Another exceptionally long folder name for constrained layout verification", directoryHint: .isDirectory))
            }
            let host = NSHostingView(rootView: MainWindow(model: model).background(Color(nsColor: .windowBackgroundColor)))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setContentSize(NSSize(width: 560, height: 360))
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            #expect(host.bounds.size == NSSize(width: 560, height: 360))
            try await NativeVisualEvidence.capture(host, name: "destination-\(mode)-manual-review")
            window.close()
        }
    }

    @Test func longDestinationAndClearRemainVisibleAndOperable() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let path = "/tmp/An exceptionally long nested export destination/Another exceptionally long folder name for constrained layout verification"
            // A real completed history makes Clear enabled and its action observable.
            let populated = AppModel(
                queue: Queue(parallelism: 1, pixelBudget: 1_000) { item, _, _, _ in .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: item.source) },
                intake: { urls, _, _ in ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }) },
                fileExists: { _ in true })
            populated.chooseExportFolder(URL(filePath: path))
            for preset in populated.presets.presets { populated.setPresetName(preset.id, String(repeating: "W", count: 70)) }
            await populated.open([URL(filePath: "/tmp/layout.jpg")])
            for _ in 0..<100 where populated.isRunning { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!populated.isRunning && populated.rows.count == 1)
            let host = NSHostingView(rootView: MainWindow(model: populated).environment(\.layoutDirection, direction).background(Color(nsColor: .windowBackgroundColor)))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            try await NativeVisualEvidence.capture(host, name: "long-destination-\(direction)")
            #expect(host.bounds.size == NSSize(width: 560, height: 360))
            #expect(host.fittingSize.width <= 561)
            let destination = try await NativeVisualEvidence.required(host, id: "destination-controls")
            let folder = try await NativeVisualEvidence.required(host, id: "export-folder")
            let clear = try await NativeVisualEvidence.required(host, id: "clear-history")
            let destinationFrame = try NativeVisualEvidence.frame(destination, in: host)
            let folderFrame = try NativeVisualEvidence.frame(folder, in: host)
            let clearFrame = try NativeVisualEvidence.frame(clear, in: host)
            for frame in [destinationFrame, folderFrame, clearFrame] {
                #expect(frame.width > 0 && frame.height > 0)
                #expect(host.bounds.contains(frame), "Control must remain inside visible content: \(frame)")
            }
            #expect(!destinationFrame.intersects(clearFrame))
            #expect(!folderFrame.intersects(clearFrame))
            #expect(NativeVisualEvidence.attribute(folder, "accessibilityValue") as? String == path)
            #expect(NativeVisualEvidence.attribute(folder, "accessibilityHelp") as? String == path)
            try NativeVisualEvidence.press(clear)
            #expect(populated.rows.isEmpty)
            #expect(!populated.canClear)
        }
    }

}

@Suite(.serialized) struct PlaceholderTests {
    @MainActor
    @Test func appDelegateQuitsAfterLastWindowClosed() {
        let quits = AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared)
        #expect(quits)
    }

    @MainActor
    @Test func quitAlertAssignsEscapeToKeepRunningAndKeepsQuitAsDefault() throws {
        let alert = AppDelegate.quitAlert(message: "Cancel remaining images and quit?")
        let buttons = alert.buttons
        #expect(buttons.map(\.title) == ["Cancel and Quit", "Keep Running"])
        #expect(buttons[0].keyEquivalent == "\r")
        #expect(buttons[1].keyEquivalent == "\u{1b}")
        #expect(buttons[1].keyEquivalentModifierMask.isEmpty)
    }

    @MainActor
    @Test(arguments: [UInt16(53), UInt16(47)])
    func cancellationKeysDismissTheModalQuitAlert(keyCode: UInt16) {
        let response = runQuitAlert { alert in
            let window = alert.window
            let modifiers: NSEvent.ModifierFlags = keyCode == 47 ? .command : []
            let characters = keyCode == 47 ? "." : "\u{1b}"
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)!
            if keyCode == 47 {
                #expect(AppDelegate.handleQuitAlertKey(event, alert: alert))
            } else {
                #expect(alert.buttons[1].performKeyEquivalent(with: event))
            }
        }
        #expect(response == NSApplication.ModalResponse.alertSecondButtonReturn.rawValue)
    }

    @MainActor
    @Test(arguments: [0, 1])
    func clickingEitherButtonReturnsItsNativeAlertResponse(buttonIndex: Int) {
        let response = runQuitAlert { alert in
            alert.buttons[buttonIndex].performClick(nil)
        }
        let expected = buttonIndex == 0
            ? NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            : NSApplication.ModalResponse.alertSecondButtonReturn.rawValue
        #expect(response == expected)
    }

    @MainActor
    private func runQuitAlert(_ interaction: @escaping (NSAlert) -> Void) -> Int {
        let alert = AppDelegate.quitAlert(message: "Cancel remaining images and quit?")
        let watchdog = Timer(timeInterval: 3, repeats: false) { _ in NSApp.abortModal() }
        let input = Timer(timeInterval: 0.1, repeats: false) { _ in interaction(alert) }
        RunLoop.main.add(watchdog, forMode: .common)
        RunLoop.main.add(input, forMode: .common)
        defer {
            watchdog.invalidate()
            input.invalidate()
        }
        return AppDelegate.runQuitAlert(alert).rawValue
    }
}

@Suite struct PresetWindowUndoTests {
    @MainActor
    @Test func windowUndoManagerRestoresPresetAndUsesNativeActionNames() {
        let model = AppModel(
            queue: Queue(parallelism: 1, pixelBudget: 1_000) { _, _, _, _ in .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: URL(filePath: "/tmp/a1-unused")) },
            intake: { _, _, _ in ScanResult(items: [], ignoredCount: 0) })
        let window = NSWindow()
        window.isReleasedWhenClosed = false
        let delegate = UndoWindowDelegate(original: window.delegate)
        window.delegate = delegate
        let undo = window.undoManager!
        undo.groupsByEvent = false
        model.presetUndoManager = undo
        let before = model.presets
        model.deletePreset(before.presets[1].id)
        let responder = PresetUndoResponder(manager: undo)
        let item = NSMenuItem(title: "Undo", action: #selector(PresetUndoResponder.undo(_:)), keyEquivalent: "z")
        #expect(responder.validateMenuItem(item))
        #expect(item.title == "Undo Delete Preset")
        responder.undo(nil)
        #expect(model.presets == before)
        #expect(undo.redoMenuItemTitle == "Redo Delete Preset")
        responder.redo(nil)
        #expect(model.presets.presets.count == before.presets.count - 1)
        window.close()
    }
}

@Suite struct PresetNativeMenuTests {
    @MainActor
    @Test func presetMenuHasNativeSelectionAndPositionShortcuts() throws {
        let menu = try #require(NSApp.mainMenu?.items.first(where: { $0.title == "Presets" })?.submenu)
        menu.update()
        let presets = Array(menu.items.prefix(while: { !$0.isSeparatorItem }))
        #expect(!presets.isEmpty)
        #expect(presets.filter { $0.state == .on }.count == 1)
        #expect(presets.allSatisfy { $0.state == .on || $0.state == .off })
        for (index, item) in presets.enumerated() {
            #expect(item.keyEquivalent == (index < 9 ? "\(index + 1)" : ""))
            if index < 9 { #expect(item.keyEquivalentModifierMask == .command) }
        }
        #expect(menu.items.contains { $0.title == "New Preset" })
        #expect(menu.items.contains { $0.title == "Edit Active Preset…" && $0.keyEquivalent.isEmpty })
        func commands(in menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in [item] + (item.submenu.map { commands(in: $0) } ?? []) }
        }
        let mainMenu = try #require(NSApp.mainMenu)
        #expect(commands(in: mainMenu).filter {
            $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
        }.count == 1)
    }
}

}

@Suite struct AppLocalizationTests {
    @Test func appCatalogResolvesAndFallsBackToEnglish() {
        #expect(Bundle.main.localizations.contains("en"))
        #expect(String(localized: "localization.app-bundle-check", bundle: .main, locale: Locale(identifier: "en")) == "English app resources")
        #expect(String(localized: "localization.app-bundle-check", bundle: .main, locale: Locale(identifier: "ko-KR")) == "English app resources")
    }
}
