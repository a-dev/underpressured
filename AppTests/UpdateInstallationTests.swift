import UnderpressuredApplication
import AppModel
import Foundation
import Sparkle
import Testing
import UnderpressuredCore
@testable import Underpressured

extension NativeAppTests {
    @MainActor
    @Test func updaterRemainsAbsentInDisabledMode() {
        let updater = DirectUpdater()
        updater.start(model: updateModel(), mode: .disabled)
        #expect(updater.controller == nil)
        #expect(!updater.isEnabled)
        #expect(!updater.canCheckForUpdates)
    }

    @MainActor
    @Test func updaterImplementsExactOptionalDelegateSelectors() {
        let updater = DirectUpdater()
        for selector in [
            "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
            "updater:willInstallUpdate:", "updater:didAbortWithError:",
            "updater:didFinishUpdateCycleForUpdateCheck:error:"
        ] { #expect(updater.responds(to: NSSelectorFromString(selector))) }
    }

    @MainActor
    @Test(arguments: ["success", "cancel", "failure"])
    func deferredContinuationRunsOnceAndKeepsAdmissionClosed(completion: String) async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let model = updateModel { _, _, _, _ in
            for await _ in stream { break }
            return completion == "success"
                ? .optimized(Savings(originalBytes: 10, newBytes: 5), notes: [], output: URL(filePath: "/tmp/out.jpg"))
                : .failed(.encodeFailed)
        }
        await model.open([URL(filePath: "/tmp/active.jpg")])
        let gate = UpdateInstallationGate(model: model)
        var calls = 0
        gate.postpone { calls += 1 }
        gate.postpone { calls += 100 }
        await Task.yield()
        #expect(calls == 0)
        if completion == "cancel" {
            let cancelling = Task { await model.cancel() }
            await Task.yield()
            continuation.finish()
            await cancelling.value
        } else {
            continuation.finish()
        }
        for _ in 0..<100 where calls == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(calls == 1)
        let next = Task { await model.open([URL(filePath: "/tmp/new.jpg")]) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.rows.count == 1)
        gate.finish()
        gate.finish()
        await next.value
        for _ in 0..<100 where model.isRunning { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(model.rows.count == 2)
        #expect(calls == 1)
    }

    @MainActor
    @Test func abortBeforeIdleDiscardsContinuationAndReopensIntake() async {
        let model = updateModel()
        let gate = UpdateInstallationGate(model: model)
        var calls = 0
        gate.postpone { calls += 1 }
        gate.finish()
        await Task.yield()
        #expect(calls == 0)
        await model.open([URL(filePath: "/tmp/after-abort.jpg")])
        #expect(model.isRunning || !model.rows.isEmpty)
    }

    @MainActor
    @Test func resumedInstallationRetainsOrdinaryQuitProtection() async {
        let (stream, release) = AsyncStream<Void>.makeStream()
        let model = updateModel { _, _, _, _ in
            for await _ in stream { break }
            return .cancelled
        }
        await model.open([URL(filePath: "/tmp/resumed.jpg")])
        let gate = UpdateInstallationGate(model: model)
        gate.installationWillProceed()
        var replies: [Bool] = []
        #expect(gate.postponeTermination { replies.append($0) })
        #expect(gate.postponeTermination { replies.append($0) })
        #expect(replies.isEmpty)
        guard case .confirm = model.quitDecision else {
            Issue.record("Resumed installation bypassed quit protection")
            release.finish()
            gate.finish()
            return
        }
        let cancelling = Task { await model.cancelForQuit() }
        release.finish()
        await cancelling.value
        #expect(model.quitDecision == .quitNow)
        #expect(replies == [true])
        gate.finish()
        #expect(replies == [true])
    }

    @MainActor
    @Test func abortingResumedInstallationCancelsPendingTerminationOnce() async {
        let (stream, release) = AsyncStream<Void>.makeStream()
        let model = updateModel { _, _, _, _ in
            for await _ in stream { break }
            return .cancelled
        }
        await model.open([URL(filePath: "/tmp/abort-resumed.jpg")])
        let gate = UpdateInstallationGate(model: model)
        gate.installationWillProceed()
        var replies: [Bool] = []
        #expect(gate.postponeTermination { replies.append($0) })
        gate.finish()
        gate.finish()
        #expect(replies == [false])
        release.finish()
        for _ in 0..<100 where model.isRunning { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(replies == [false])
        #expect(!gate.postponeTermination { _ in Issue.record("Ordinary quit intercepted") })
    }

    @MainActor
    @Test func installationWaitsForPendingScanAndProcessingBeforeHandoff() async {
        let scanStarted = AsyncStream<Void>.makeStream()
        let scanRelease = DispatchSemaphore(value: 0)
        let processingStarted = AsyncStream<Void>.makeStream()
        let processingRelease = AsyncStream<Void>.makeStream()
        defer {
            scanRelease.signal()
            scanStarted.continuation.finish()
            processingStarted.continuation.finish()
            processingRelease.continuation.finish()
        }
        let model = AppModel(
            queue: Queue(parallelism: 1) { _, _, _, _ in
                processingStarted.continuation.yield(())
                for await _ in processingRelease.stream { break }
                return .failed(.encodeFailed)
            },
            intake: { urls, _, _ in
                scanStarted.continuation.yield(())
                _ = scanRelease.wait(timeout: .now() + 10)
                return ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) })
            }, updateInterval: .seconds(30))
        let opening = Task { await model.open([URL(filePath: "/tmp/held-update-scan.jpg")]) }
        var scans = scanStarted.stream.makeAsyncIterator()
        _ = await scans.next()
        let gate = UpdateInstallationGate(model: model)
        defer { gate.finish() }
        var calls = 0
        gate.postpone { calls += 1 }
        #expect(calls == 0)
        #expect(model.isRunning)
        scanRelease.signal()
        await opening.value
        var processing = processingStarted.stream.makeAsyncIterator()
        _ = await processing.next()
        #expect(calls == 0)
        processingRelease.continuation.finish()
        for _ in 0..<200 where calls == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(calls == 1)
        #expect(!model.isRunning)
        #expect(model.remainingCount == 0)
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.stateText == "Failed")
    }

    @MainActor
    private func updateModel(pipeline: @escaping ItemPipeline = { _, _, _, _ in .cancelled }) -> AppModel {
        AppModel(queue: Queue(parallelism: 1, pixelBudget: 1_000_000, pipeline: pipeline),
                 intake: { urls, _, _ in ScanResult(items: urls.map { Item(source: $0, droppedRoot: nil) }, ignoredCount: 0) })
    }
}
