import UnderpressuredCore
import UnderpressuredApplication
import IOKit.pwr_mgt

/// Holds an IOKit power assertion while the Queue runs, so the Mac doesn't idle-sleep (spec §3.7).
@MainActor
public final class PowerAssertionSleepPreventer: SleepPreventer {
    private var assertionID: IOPMAssertionID?

    public init() {}

    public func setPreventing(_ preventing: Bool, reason: String) {
        if preventing {
            guard assertionID == nil else { return }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString, &id)
            if result == kIOReturnSuccess { assertionID = id }
        } else if let id = assertionID {
            IOPMAssertionRelease(id)
            assertionID = nil
        }
    }

    isolated deinit {
        if let id = assertionID { IOPMAssertionRelease(id) }
    }
}
