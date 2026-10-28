import UnderpressuredApplication
import Foundation

/// What quitting does right now (spec §3.7).
public enum QuitDecision: Sendable, Equatable {
    case quitNow
    /// Ask first; the message is the alert text.
    case confirm(message: String)
}

extension AppModel {
    /// Ask before quitting if intake is pending or any Items are Waiting or Processing.
    public var quitDecision: QuitDecision {
        applyPending()  // the count must not lag behind the throttle
        let activity = processingActivity
        if activity.pendingScans > 0 || activity.pendingAdmissions > 0 {
            return .confirm(message: String(localized: "Cancel scanning and any remaining images and quit?", bundle: .module, comment: "Quit confirmation while scanning files."))
        }
        let count = activity.unfinishedItems
        guard count > 0 else { return .quitNow }
        return .confirm(message: String(localized: "quit.remaining", defaultValue: "Cancel \(count) remaining images and quit?", bundle: .module, comment: "Quit confirmation. Integer is unfinished image count; use plural variations."))
    }

    /// Confirmed quit: applies Cancel (§7.6), then returns once intake and the Queue are idle.
    public func cancelForQuit() async {
        await cancel()
        await untilIdle()
    }
}
