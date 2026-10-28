#if DIRECT_DISTRIBUTION
import AppModel
import Combine
import Foundation
import Sparkle

/// Owns only the install handoff; Sparkle owns preferences, downloads, and update UI.
@MainActor
final class UpdateInstallationGate {
    private let model: AppModel
    private var reservation: UUID?
    private var generation = 0
    private var installationProceeding = false
    private var terminationReply: ((Bool) -> Void)?

    init(model: AppModel) { self.model = model }

    func postpone(_ continuation: @escaping () -> Void) {
        guard reservation == nil else { return }
        generation += 1
        let current = generation
        reservation = model.reserveIdleOperation { [weak self] in
            // Sparkle must receive the delegate's YES before its continuation is invoked.
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.reservation != nil else { return }
                continuation()
            }
        }
    }

    /// Resumed/no-relaunch paths can bypass postponement. Hold new intake while the
    /// asynchronous termination delegate drains any work already admitted.
    func installationWillProceed() {
        installationProceeding = true
        guard reservation == nil else { return }
        reservation = model.reserveIdleOperation { [weak self] in self?.replyToTermination(true) }
    }

    /// AppKit's asynchronous termination reply covers paths that bypass Sparkle's
    /// postponement hook. Current work completes; intake stays reserved throughout.
    func postponeTermination(_ reply: @escaping (Bool) -> Void) -> Bool {
        guard installationProceeding else { return false }
        _ = model.quitDecision // flush throttled events before deciding
        guard model.isRunning else { return false }
        if terminationReply == nil { terminationReply = reply }
        return true
    }

    private func replyToTermination(_ shouldTerminate: Bool) {
        let reply = terminationReply
        terminationReply = nil
        reply?(shouldTerminate)
    }

    func finish() {
        generation += 1
        installationProceeding = false
        replyToTermination(false)
        if let reservation { model.releaseIdleOperation(reservation) }
        reservation = nil
    }
}

@MainActor
final class DirectUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController?
    private var gate: UpdateInstallationGate?
    private var observations: [NSKeyValueObservation] = []

    var isEnabled: Bool { controller != nil }
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func start(model: AppModel, mode: DirectUpdateConfiguration.Mode = DirectUpdateConfiguration.mode) {
        guard mode != .disabled, controller == nil else { return }
        gate = UpdateInstallationGate(model: model)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
        ]
        objectWillChange.send()
        controller.startUpdater()
    }

    func postponeTermination(_ reply: @escaping (Bool) -> Void) -> Bool {
        gate?.postponeTermination(reply) ?? false
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let gate else { return false }
        gate.postpone(installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        gate?.installationWillProceed()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { gate?.finish() }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        gate?.finish()
    }
}
#endif
