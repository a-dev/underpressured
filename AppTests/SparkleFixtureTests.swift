import UnderpressuredApplication
import AppKit
import AppModel
import UnderpressuredCore
import Foundation
import Sparkle
import Testing

/// Observe Sparkle's real standard UI; dismiss modal alerts using their actual buttons.
@MainActor
private final class FixtureStandardDriver: SPUStandardUserDriver {
    var permissionShown = false
    var found = false
    var error: NSError?
    var current = false
    var displayedButtons: [String] = []

    private func dismissModal() {
        let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow else { return }
                let buttons = fixtureButtons(window.contentView)
                guard let button = buttons.first(where: { $0.isEnabled && !$0.isHidden }) else { return }
                self?.displayedButtons = buttons.map(\.title)
                print("SPARKLE FIXTURE modal title=\(window.title) buttons=\(buttons.map(\.title))")
                button.performClick(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
    }

    override func show(_ request: SPUUpdatePermissionRequest,
                                              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        permissionShown = true
        super.show(request, reply: reply)
    }

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        self.error = error as NSError
        dismissModal()
        super.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    override func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        current = true
        dismissModal()
        super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        found = true
        super.showUpdateFound(with: appcastItem, state: state, reply: reply)
    }
}

@MainActor
private func fixtureButtons(_ view: NSView?) -> [NSButton] {
    guard let view else { return [] }
    return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { fixtureButtons($0) }
}

@MainActor
private final class FixtureDelegate: NSObject, SPUUpdaterDelegate {
    var finished = false
    var declinedScheduling = false
    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) { declinedScheduling = true }
    var processingModel: AppModel?
    var downloadedDuringProcessing = false
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        downloadedDuringProcessing = processingModel?.isRunning == true
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finished = true
    }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { true }
}

extension NativeAppTests {
    @MainActor
    @Test(.timeLimit(.minutes(1))) func standardConsentAcceptedDeclinedAndChangedLater() async throws {
        for accepts in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appending(path: "SparkleConsent-\(UUID()).app")
            let contents = directory.appending(path: "Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let identifier = "com.devsboat.phase5.consent.\(UUID().uuidString)"
            let info: [String: Any] = [
                "CFBundleIdentifier": identifier, "CFBundleName": "Consent Fixture", "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0", "SUFeedURL": "http://127.0.0.1:1/current.xml",
                "SUPublicEDKey": Data(0..<32).base64EncodedString(), "SUAllowsAutomaticUpdates": false
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appending(path: "Info.plist"))
            let delegate = FixtureDelegate()
            #expect(delegate.responds(to: NSSelectorFromString("updaterShouldPromptForPermissionToCheckForUpdates:")))
            let bundle = try #require(Bundle(url: directory))
            let driver = FixtureStandardDriver(hostBundle: bundle, delegate: nil)
            let updater = SPUUpdater(hostBundle: bundle, applicationBundle: .main, userDriver: driver, delegate: delegate)
            try updater.start()
            for _ in 0..<100 where !driver.permissionShown { try await Task.sleep(for: .milliseconds(10)) }
            #expect(driver.permissionShown)
            let buttons = NSApp.windows.filter(\.isVisible).flatMap { fixtureButtons($0.contentView) }
            let title = accepts ? "Check Automatically" : "Don’t Check"
            try #require(buttons.first(where: { $0.title == title })).performClick(nil)
            for _ in 0..<100 where updater.automaticallyChecksForUpdates != accepts {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(updater.automaticallyChecksForUpdates == accepts)
            if !accepts {
                for _ in 0..<100 where !delegate.declinedScheduling { try await Task.sleep(for: .milliseconds(10)) }
                #expect(delegate.declinedScheduling)
            }
            #expect(!updater.automaticallyDownloadsUpdates)
            updater.automaticallyChecksForUpdates = !accepts
            #expect(updater.automaticallyChecksForUpdates == !accepts)
            updater.automaticallyChecksForUpdates = false
            print("SPARKLE FIXTURE consent accepts=\(accepts), later preference changes authoritative")
            UserDefaults.standard.removePersistentDomain(forName: identifier)
            try FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor
    @Test(.timeLimit(.minutes(1))) func standardSparkleUIWithLoopbackFeeds() async throws {
        let artifactRoot = FileManager.default.temporaryDirectory.appending(path: "SparkleArchive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        let payload = artifactRoot.appending(path: "Update Fixture.app/Contents")
        try FileManager.default.createDirectory(at: payload.appending(path: "MacOS"), withIntermediateDirectories: true)
        let identifierPrefix = "com.devsboat.phase5.fixture.\(UUID().uuidString)"
        let payloadInfo: [String: Any] = ["CFBundleIdentifier": identifierPrefix + ".invalid-signature", "CFBundleVersion": "9999",
            "CFBundleName": "Update Fixture", "CFBundleShortVersionString": "9999", "CFBundleExecutable": "Fixture",
            "SUPublicEDKey": Data(0..<32).base64EncodedString()]
        try PropertyListSerialization.data(fromPropertyList: payloadInfo, format: .xml, options: 0)
            .write(to: payload.appending(path: "Info.plist"))
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: payload.appending(path: "MacOS/Fixture"))
        let archive = artifactRoot.appending(path: "update.zip")
        let zip = Process()
        zip.executableURL = URL(filePath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", payload.deletingLastPathComponent().path, archive.path]
        try zip.run(); zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        process.arguments = [root.appending(path: "scripts/update-fixture-server.py").path, "--port", "0",
                             "--archive", archive.path, "--signature", Data(repeating: 0, count: 64).base64EncodedString()]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        let base = try #require(line.split(separator: " ").last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(base.hasPrefix("http://127.0.0.1:"))

        for scenario in ["current", "available", "malformed", "download-failure", "invalid-signature", "offline"] {
            // Sparkle keys pending installer state by bundle identity, not fixture path.
            let identifier = identifierPrefix + "." + scenario
            let directory = FileManager.default.temporaryDirectory.appending(path: "SparkleFixture-\(UUID()).app")
            let contents = directory.appending(path: "Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let feed = scenario == "offline" ? "http://127.0.0.1:1/offline.xml" : base + scenario + ".xml"
            let info: [String: Any] = [
                "CFBundleIdentifier": identifier, "CFBundleName": "Update Fixture", "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0", "SUFeedURL": feed,
                "SUPublicEDKey": Data(0..<32).base64EncodedString(),
                "SUEnableAutomaticChecks": false, "SUAllowsAutomaticUpdates": false
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appending(path: "Info.plist"))
            let bundle = try #require(Bundle(url: directory))
            let delegate = FixtureDelegate()
            let (work, releaseWork) = AsyncStream<Void>.makeStream()
            let model = AppModel(queue: Queue(parallelism: 1, pixelBudget: 1_000) { _, _, _, _ in
                for await _ in work { break }
                return .cancelled
            }, intake: { urls, _, _ in ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: 0) })
            await model.open([URL(filePath: "/tmp/processing-during-download.jpg")])
            delegate.processingModel = model
            defer { releaseWork.finish() }
            let driver = FixtureStandardDriver(hostBundle: bundle, delegate: nil)
            let updater = SPUUpdater(hostBundle: bundle, applicationBundle: .main, userDriver: driver, delegate: delegate)
            try updater.start()
            #expect(!updater.automaticallyChecksForUpdates)
            #expect(!updater.automaticallyDownloadsUpdates)
            #expect(updater.canCheckForUpdates)
            updater.checkForUpdates()
            #expect(!updater.canCheckForUpdates)
            for _ in 0..<500 where !driver.found && !delegate.finished { try await Task.sleep(for: .milliseconds(10)) }
            if driver.found {
                let buttons = NSApp.windows.filter(\.isVisible).flatMap { fixtureButtons($0.contentView) }
                print("SPARKLE FIXTURE \(scenario) available buttons=\(buttons.map(\.title))")
                #expect(buttons.filter { $0.title == "Automatically download and install updates in the future" }
                    .allSatisfy { $0.isHiddenOrHasHiddenAncestor || !$0.isEnabled })
                let title = scenario == "available" ? "Skip This Version" : "Install Update"
                let button = try #require(buttons.first(where: { $0.title == title }))
                button.performClick(nil)
            }
            for _ in 0..<1_000 where !delegate.finished { try await Task.sleep(for: .milliseconds(10)) }
            #expect(delegate.finished)
            #expect(updater.canCheckForUpdates)
            if scenario == "current" { #expect(driver.current) }
            else if scenario == "available" { #expect(driver.found); #expect(driver.error == nil) }
            else {
                #expect(driver.error != nil); #expect(!driver.displayedButtons.isEmpty)
                let expected = scenario == "malformed" ? 1000 : scenario == "invalid-signature" ? 4005 : 2001
                #expect(driver.error?.domain == "SUSparkleErrorDomain")
                #expect(driver.error?.code == expected)
            }
            if scenario == "invalid-signature" { #expect(delegate.downloadedDuringProcessing); #expect(model.isRunning) }
            releaseWork.finish()
            print("SPARKLE FIXTURE result \(scenario): found=\(driver.found) current=\(driver.current) error=\(driver.error?.description ?? "none")")
            UserDefaults.standard.removePersistentDomain(forName: identifier)
            try FileManager.default.removeItem(at: directory)
        }
    }
}
