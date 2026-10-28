import UnderpressuredApplication
import AppKit
import AppModel
import QuickLookUI
import SwiftUI
import Testing
import UnderpressuredCore
@testable import Underpressured

@MainActor
extension NativeAppTests.ItemListFocusTests {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @Test func selectedFilterAccessibilityAndAction() async throws {
        var summary = RunSummary()
        summary.images = 3
        summary.failed = 1
        summary.skipped = 1
        summary.cancelled = 1
        let model = AppModel(queue: Queue(parallelism: 1, pixelBudget: 1_000) { _, _, _, _ in .cancelled }, intake: { _, _, _ in ScanResult(items: []) })
        for filter in OutcomeFilter.allCases {
            let host = NSHostingView(rootView: BannerView(banner: Presentation.banner(summary, filter: filter), toggle: model.toggleFilter))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 70), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            try NativeVisualEvidence.dumpAX(host, name: "filter-\(filter)")
            for expected in OutcomeFilter.allCases {
                let button = try await NativeVisualEvidence.required(host, id: "outcome-filter-\(expected)")
                let value = NativeVisualEvidence.attribute(button, "accessibilityValue") as? String ?? ""
                #expect(expected == filter ? !value.isEmpty : value.isEmpty, "Exactly the selected filter must expose selection")
                #expect(value == (expected == filter ? AccessibilityText.filterButtonValue(isOn: true) ?? "" : ""))
                model.filter = filter
                try NativeVisualEvidence.press(button)
                #expect(model.filter == (expected == filter ? nil : expected))
                try NativeVisualEvidence.press(button)
                #expect(model.filter == (expected == filter ? expected : nil))
            }
            #expect(!NativeVisualEvidence.elements(host).contains { NativeVisualEvidence.attribute($0, "accessibilityRole") as? String == "AXImage" })
        }
    }

    @Test func selectedFilterMatchesReviewedCheckmark() async throws {
        var summary = RunSummary()
        summary.images = 3
        summary.failed = 1
        summary.skipped = 1
        summary.cancelled = 1
        let os = ProcessInfo.processInfo.operatingSystemVersion
        try #require(os.majorVersion == 27 && os.minorVersion == 0 && os.patchVersion == 1,
            "Baseline reviewed on macOS 27.0.1 / Xcode 27.1; explicitly review other runners")
        try #require(Bundle.main.object(forInfoDictionaryKey: "DTXcodeBuild") as? String == "27A9275",
            "Baseline reviewed with Xcode 27.1 build 27A9275; explicitly review other toolchains")
        for filter in OutcomeFilter.allCases {
            let host = NSHostingView(rootView: BannerView(banner: Presentation.banner(summary, filter: filter), toggle: { _ in })
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.layoutDirection, .leftToRight).frame(width: 560).background(Color.white))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 70), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            host.displayIfNeeded()
            let bitmap = try await NativeVisualEvidence.capture(host, name: "filter-\(filter)")
            #expect(host.fittingSize.width <= 560)
            let selected = try await NativeVisualEvidence.required(host, id: "outcome-filter-\(filter)")
            let rect = try NativeVisualEvidence.frame(selected, in: host)
            let image = try #require(bitmap.cgImage)
            let scale = CGFloat(image.width) / host.bounds.width
            #expect(scale == 2, "Reviewed fixture requires 2× backing scale")
            // Only the leading indicator, excluding the title and button edges.
            let cropRect = CGRect(x: (rect.minX + 10) * scale,
                y: (host.isFlipped ? rect.midY - 6 : host.bounds.height - rect.midY - 6) * scale, width: 12 * scale, height: 12 * scale).integral
            let crop = try #require(image.cropping(to: cropRect))
            let actual = NSBitmapImageRep(cgImage: crop)
            try #require(actual.representation(using: .png, properties: [:])).write(to: NativeVisualEvidence.directory.appending(path: "checkmark-\(filter).png"))
            let baselineURL = try #require(Bundle(for: NativeBaselineBundle.self).url(forResource: "checkmark-macos27", withExtension: "png"))
            let baseline = try #require(NSBitmapImageRep(data: try Data(contentsOf: baselineURL)), "Reviewed checkmark baseline must exist")
            #expect(actual.pixelsWide == baseline.pixelsWide && actual.pixelsHigh == baseline.pixelsHigh)
            var error = 0.0
            for y in 0..<min(actual.pixelsHigh, baseline.pixelsHigh) {
                for x in 0..<min(actual.pixelsWide, baseline.pixelsWide) {
                    let a = try #require(actual.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let b = try #require(baseline.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    error += Double(abs(a.redComponent - b.redComponent))
                    error += Double(abs(a.greenComponent - b.greenComponent))
                    error += Double(abs(a.blueComponent - b.blueComponent))
                }
            }
            let meanError = error / Double(actual.pixelsWide * actual.pixelsHigh * 3)
            print("CHECKMARK \(filter) mean RGB error=\(meanError)")
            #expect(meanError < 0.025, "Checkmark indicator differs from reviewed baseline")
        }
    }

    @Test func selectionContextMenuUsesClickedRowAndDisablesUnavailableFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["a.jpg", "failed.jpg", "b.jpg"].map { root.appending(path: $0) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        for url in urls { try data.write(to: url) }
        let model = AppModel(
            queue: Queue(parallelism: 1, pixelBudget: 1_000) { item, _, _, _ in
                item.source.lastPathComponent == "failed.jpg" ? .failed(.cantRead) :
                    .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: item.source)
            },
            intake: { urls, _, _ in ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: 0) },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) })
        await model.open(urls)
        for _ in 0..<100 where model.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        var opened: [URL] = []
        var revealed: [[URL]] = []
        let host = NSHostingView(rootView: ItemListView(model: model,
            openFile: { opened.append($0) }, revealFiles: { revealed.append($0) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        let table = try #require(descendants(host).compactMap { $0 as? NSTableView }.first)
        #expect(table.numberOfRows == 4) // Section header, then the three items.
        func menu(_ row: Int) throws -> NSMenu {
            let point = table.convert(NSPoint(x: 100, y: table.rect(ofRow: row).midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let menu = try #require(table.menu(for: event))
            menu.update()
            #expect(menu.items.map(\.title) == ["Open", "Quick Look", "Show in Finder"])
            return menu
        }
        func invoke(_ menu: NSMenu, _ index: Int) throws {
            let item = menu.items[index]
            #expect(item.isEnabled)
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
        }
        model.selection = [model.rows[0].id]
        try await Task.sleep(for: .milliseconds(200))
        // Clicking an unselected success must not operate on the unrelated selection.
        try invoke(menu(3), 0)
        #expect(opened == [urls[2]])
        #expect(try menu(2).items.allSatisfy { !$0.isEnabled })
        model.selection = Set(model.rows.map(\.id))
        try await Task.sleep(for: .milliseconds(200))
        let mixed = try menu(1)
        try invoke(mixed, 0)
        #expect(opened == [urls[2], urls[0], urls[2]])
        try invoke(mixed, 2)
        #expect(revealed == [[urls[0], urls[2]]])
        try invoke(mixed, 1)
        try await Task.sleep(for: .milliseconds(300))
        let panel = try #require(QLPreviewPanel.shared())
        defer { panel.orderOut(nil) }
        #expect(panel.isVisible)
        #expect(panel.currentPreviewItemIndex == 0)
        #expect(panel.dataSource?.numberOfPreviewItems(in: panel) == 2)
        let first = panel.dataSource?.previewPanel(panel, previewItemAt: 0)
        let second = panel.dataSource?.previewPanel(panel, previewItemAt: 1)
        #expect(first?.previewItemURL == urls[0])
        #expect(second?.previewItemURL == urls[2])
        // Files can disappear after completion or even after menu construction.
        try FileManager.default.removeItem(at: urls[0])
        try invoke(mixed, 2)
        #expect(revealed.last == [urls[2]])
        try FileManager.default.removeItem(at: urls[2])
        #expect(try menu(1).items.allSatisfy { !$0.isEnabled })
        try invoke(mixed, 0) // A stale enabled command still revalidates.
        #expect(opened == [urls[2], urls[0], urls[2]])
    }
}

/// Shared native diagnostics. AX frames use screen coordinates; convert explicitly to content coordinates.
@MainActor
enum NativeVisualEvidence {
    static let directory: URL = {
        let root = ProcessInfo.processInfo.environment["UP_UI_ARTIFACTS"].map { URL(filePath: $0) }
            ?? FileManager.default.temporaryDirectory.appending(path: "underpressured-ui-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("UI ARTIFACTS: \(root.path)")
        return root
    }()

    static func attribute(_ element: NSObject, _ name: String) -> Any? {
        element.responds(to: NSSelectorFromString(name)) ? element.value(forKey: name) : nil
    }

    static func elements(_ root: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 30 else { return [] }
        return [root] + (attribute(root, "accessibilityChildren") as? [NSObject] ?? []).flatMap {
            elements($0, depth: depth + 1)
        }
    }

    /// SwiftUI publishes its AX tree asynchronously after layout; slower CI runners need more than a fixed sleep.
    static func required(_ root: NSObject, id: String, timeout: Duration = .seconds(3)) async throws -> NSObject {
        let deadline = ContinuousClock.now + timeout
        var matches = elements(root).filter { attribute($0, "accessibilityIdentifier") as? String == id }
        while matches.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            matches = elements(root).filter { attribute($0, "accessibilityIdentifier") as? String == id }
        }
        #expect(matches.count == 1, "Required unique AX control: \(id)")
        return try #require(matches.first, "Missing AX control: \(id)")
    }

    static func frame(_ element: NSObject, in host: NSView) throws -> NSRect {
        let screen = try #require(attribute(element, "accessibilityFrame") as? NSValue).rectValue
        let window = try #require(host.window)
        return host.convert(window.convertFromScreen(screen), from: nil)
    }

    static func press(_ element: NSObject) throws {
        let action = NSSelectorFromString("accessibilityPerformPress")
        #expect(element.responds(to: action))
        _ = element.perform(action)
    }

    static func dumpAX(_ host: NSView, name: String) throws {
        try axDescription(host).write(to: directory.appending(path: "\(name)-ax.txt"), atomically: true, encoding: .utf8)
    }

    static func axDescription(_ host: NSView) -> String {
        elements(host).map { element in
            ["accessibilityRole", "accessibilityIdentifier", "accessibilityLabel", "accessibilityValue", "accessibilitySelected", "accessibilityHelp", "accessibilityFrame"].map {
                "\($0)=\(attribute(element, $0) ?? "nil")"
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    @discardableResult
    static func capture(_ host: NSView, name: String) async throws -> NSBitmapImageRep {
        try dumpAX(host, name: name)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appending(path: "\(name).png"))
        if let frame = host.window?.contentView?.superview {
            let full = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: full)
            try #require(full.representation(using: .png, properties: [:])).write(to: directory.appending(path: "\(name)-window.png"))
        }
        return bitmap
    }
}

private final class NativeBaselineBundle: NSObject {}
