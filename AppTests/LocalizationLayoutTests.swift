@testable import MacPlatform
import UnderpressuredApplication
import AppKit
@testable import AppModel
import SwiftUI
import Testing
import UnderpressuredCore
@testable import Underpressured

extension NativeAppTests {
@MainActor
@Suite(.serialized) struct LocalizationLayoutTests {
    @Test func completionBannerWithLargeCountsAndLongFilters() async throws {
        var summary = RunSummary()
        summary.images = 3_000_000
        summary.finished = summary.images
        summary.failed = 1_000_000
        summary.skipped = 1_000_000
        summary.cancelled = 1_000_000
        summary.ignored = 1_000_000
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            var banner = Presentation.banner(summary, filter: .failed)
            let titles = ["1.000.000 fehlgeschlagen", "1.000.000 übersprungen", "1.000.000 abgebrochen"]
            for index in banner.filters.indices { banner.filters[index].title = titles[index] }
            for width in [560.0, 900.0] {
                try await captureForManualReview(BannerView(banner: banner, toggle: { _ in }), language: "stress", direction: direction,
                    name: "banner-\(direction)-\(Int(width))", size: NSSize(width: width, height: 180))
            }
        }
    }

    @Test func localizedSurfacesAtMinimumSize() async throws {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let direction: LayoutDirection = language == "ar" ? .rightToLeft : .leftToRight
        #expect(AppLocalization.layoutDirection == direction)
        print("LOCALIZATION UI language=\(language), settings=\(GeneralSettingsView.resolvedLanguage)")
        let model = AppModel(
            queue: Queue(parallelism: 1, pixelBudget: 1_000) { item, _, _, _ in
                try? await Task.sleep(for: .milliseconds(350))
                return switch item.source.lastPathComponent {
                case "failed.jpg": .failed(.cantRead)
                case "skipped.jpg": .skipped(.alreadyOptimal, notes: [])
                case "cancelled.jpg": .cancelled
                default: .optimized(Savings(originalBytes: 10_000, newBytes: 5_000), notes: [.resized(from: 900, to: 300)], output: item.source)
                }
            },
            intake: { urls, _, _ in ScanResult(items: urls.map { Item(source: $0, droppedRoot: URL(filePath: "/tmp/صور Trip 12")) }, ignoredCount: 3, failures: [ScanFailure(url: URL(filePath: "/tmp/Unreadable"), reason: .noPermission)]) },
            fileExists: { _ in true })
        try await captureForManualReview(MainWindow(model: model), language: language, direction: direction, name: "empty", size: NSSize(width: 560, height: 360))
        try await captureForManualReview(PresetPopover(model: model, id: model.presets.activeID), language: language, direction: direction, name: "preset", size: NSSize(width: 480, height: 620))
        try await captureForManualReview(GeneralSettingsView(model: model).environmentObject(DirectUpdater()), language: language, direction: direction, name: "general", size: NSSize(width: 560, height: 390))
        let deniedNotifier = UserNotifier(readAuthorization: { .denied }, authorize: { Issue.record("Denied permission must not be requested again") })
        await deniedNotifier.refreshAuthorization()
        try await captureForManualReview(GeneralSettingsView(model: model, notifier: deniedNotifier).environmentObject(DirectUpdater()), language: language, direction: direction, name: "notifications-denied", size: NSSize(width: 560, height: 390))
        try await captureForManualReview(SupportSettingsView(), language: language, direction: direction, name: "support", size: NSSize(width: 560, height: 390))
        for preset in model.presets.presets { model.setPresetName(preset.id, String(repeating: "W", count: 70)) }
        model.chooseExportFolder(URL(filePath: "/tmp/صور Trip 12/An exceptionally long nested export destination/export (2026) — الصور"))
        let names = ["صورة 12 — photo.jpg", "failed.jpg", "skipped.jpg", "cancelled.jpg"]
        await model.open(names.map { URL(filePath: "/tmp/صور Trip 12/\($0)") })
        try await captureForManualReview(MainWindow(model: model), language: language, direction: direction, name: "processing", size: NSSize(width: 560, height: 360))
        for _ in 0..<100 where model.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isRunning)
        #expect(model.rows.count == 4)
        #expect(model.intakeFailures.count == 1)
        #expect(model.rows.allSatisfy { !$0.accessibilityLabel.isEmpty })
        try await captureForManualReview(MainWindow(model: model), language: language, direction: direction, name: "results", size: NSSize(width: 560, height: 360))
        let alert = AppDelegate.quitAlert(message: model.rows[0].accessibilityLabel)
        #expect(alert.buttons.allSatisfy { !$0.title.isEmpty })
    }

    fileprivate func captureForManualReview(_ view: some View, language: String, direction: LayoutDirection, name: String, size: NSSize) async throws {
        let host = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: language)).environment(\.layoutDirection, direction).background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Underpressured"
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        #expect(host.bounds.width == size.width)
        #expect(host.bounds.height <= size.height)
        #expect(host.fittingSize.width <= size.width + 1)
        let directory = NativeVisualEvidence.directory.appending(path: language, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await NativeVisualEvidence.capture(host, name: "\(language)/\(name)")
        var descriptions: [String] = []
        var frames: [String: NSRect] = [:]
        // SwiftUI's virtual AX elements implement selectors without declaring the full protocol.
        func visit(_ element: NSObject, depth: Int) {
            guard depth < 20 else { return }
            func attribute(_ name: String) -> Any? {
                element.responds(to: NSSelectorFromString(name)) ? element.value(forKey: name) : nil
            }
            let label = attribute("accessibilityLabel") as? String ?? ""
            let frame = (attribute("accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            descriptions.append("\(String(repeating: "  ", count: depth))\(attribute("accessibilityRole") ?? "unknown") \(label) \(frame)")
            if name.hasPrefix("banner-"), attribute("accessibilityRole") as? String == "AXStaticText" {
                #expect(frame.width >= 200, "The completion summary must not be squeezed into a clipped column")
            }
            if !label.isEmpty { frames[label] = frame }
            for child in attribute("accessibilityChildren") as? [NSObject] ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(host, depth: 0)
        if name == "results" {
            let destination = try NativeVisualEvidence.required(host, id: "destination-controls")
            let folder = try NativeVisualEvidence.required(host, id: "export-folder")
            let clear = try NativeVisualEvidence.required(host, id: "clear-history")
            let destinationFrame = try NativeVisualEvidence.frame(destination, in: host)
            let folderFrame = try NativeVisualEvidence.frame(folder, in: host)
            let clearFrame = try NativeVisualEvidence.frame(clear, in: host)
            for frame in [destinationFrame, folderFrame, clearFrame] {
                #expect(frame.width > 0 && frame.height > 0 && host.bounds.contains(frame))
            }
            #expect(!destinationFrame.intersects(clearFrame))
            #expect(!folderFrame.intersects(clearFrame))
            let path = "/tmp/صور Trip 12/An exceptionally long nested export destination/export (2026) — الصور"
            #expect(NativeVisualEvidence.attribute(folder, "accessibilityValue") as? String == path)
            #expect(NativeVisualEvidence.attribute(folder, "accessibilityHelp") as? String == path)
        }
        if name == "empty", direction == .rightToLeft {
            let first = frames[AccessibilityText.presetBadge(name: Preset.starters[0].displayName)]
            let second = frames[AccessibilityText.presetBadge(name: Preset.starters[1].displayName)]
            #expect(try #require(first).midX > #require(second).midX)
        }
        func menuTitles(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { [$0.title] + ($0.submenu.map(menuTitles) ?? []) }
        }
        descriptions += NSApp.mainMenu.map(menuTitles) ?? []
        try descriptions.joined(separator: "\n").write(to: directory.appending(path: "\(name)-layout-ax.txt"), atomically: true, encoding: .utf8)

    }
}

@MainActor
@Suite(.serialized) struct ErrorScreenshotTests {
    @Test func intakePopoverFitsShortAndLongLists() throws {
        let failure = ScanFailure(url: URL(filePath: "/Example Photos/Private Folder"), reason: .noPermission)
        let single = NSHostingView(rootView: IntakeFailureDetails(failures: [failure]))
        #expect(single.fittingSize.width == 400)
        #expect(single.fittingSize.height <= 100)
        let many = NSHostingView(rootView: IntakeFailureDetails(failures: (0..<20).map {
            ScanFailure(url: URL(filePath: "/Example Photos/Private Folder \($0)"), reason: .noPermission)
        }))
        #expect(many.fittingSize.height <= 240)
        #expect(many.fittingSize.height >= 200)
    }

    @Test func wholeWindowErrorStatesManualReviewCaptures() async throws {
        let groups: [(String, [(String, FailReason)])] = [
            ("file-errors", [
                ("missing-photo.jpg", .fileNotFound),
                ("destination-collision.jpg", .fileAlreadyExists),
                ("permission-denied.jpg", .noPermission),
                ("disk-full.jpg", .diskFull),
            ]),
            ("destination-errors", [
                ("unexpected-io.jpg", .fileIOFailed),
                ("trash-unavailable.jpg", .noTrash),
                ("export-unavailable.jpg", .exportFolderUnavailable),
                ("destination-changed.jpg", .destinationChanged),
            ]),
            ("processing-errors", [
                ("unreadable-image.jpg", .cantRead),
                ("source-changed.jpg", .fileChanged),
                ("encoding-failed.jpg", .encodeFailed),
                ("lossless-jpeg-failed.jpg", .losslessEncoderUnavailable),
            ]),
        ]
        for (name, examples) in groups {
            let reasons = Dictionary(uniqueKeysWithValues: examples)
            let model = AppModel(
                queue: Queue(parallelism: 1, pixelBudget: 1_000) { item, _, _, _ in
                    .failed(reasons[item.source.lastPathComponent]!)
                },
                intake: { urls, _, _ in ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }) },
                settingsStore: InMemorySettingsStore(), fileExists: { _ in true })
            await model.open(examples.map { URL(filePath: "/Example Photos/\($0.0)") })
            for _ in 0..<100 where model.isRunning { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!model.isRunning)
            #expect(model.rows.count == examples.count)
            try await LocalizationLayoutTests().captureForManualReview(MainWindow(model: model), language: "errors", direction: .leftToRight,
                name: name, size: NSSize(width: 820, height: 560))
        }
        let intakeModel = AppModel(
            queue: Queue(parallelism: 1, pixelBudget: 1_000) { _, _, _, _ in .cancelled },
            intake: { _, _, _ in ScanResult(failures: [
                ScanFailure(url: URL(filePath: "/Example Photos/Private Folder"), reason: .noPermission)
            ]) }, settingsStore: InMemorySettingsStore())
        await intakeModel.open([URL(filePath: "/Example Photos/Private Folder")])
        for _ in 0..<100 where intakeModel.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        try await LocalizationLayoutTests().captureForManualReview(MainWindow(model: intakeModel), language: "errors", direction: .leftToRight,
            name: "intake-warning", size: NSSize(width: 700, height: 430))
        let denied = UserNotifier(readAuthorization: { .denied }, authorize: {})
        await denied.refreshAuthorization()
        try await LocalizationLayoutTests().captureForManualReview(
            GeneralSettingsView(model: intakeModel, notifier: denied).environmentObject(DirectUpdater()),
            language: "errors", direction: .leftToRight, name: "notifications-blocked", size: NSSize(width: 560, height: 500))
    }
}

}
