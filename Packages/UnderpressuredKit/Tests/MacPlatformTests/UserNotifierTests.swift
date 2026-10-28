import UnderpressuredApplication
@testable import MacPlatform
import Foundation
import Testing
import UserNotifications

@MainActor
@Suite(.serialized) struct UserNotifierTests {
    @Test func deniedIsVisibleAndRefreshesWithoutChangingPreference() async {
        let original = UserDefaults.standard.object(forKey: UserNotifier.enabledKey)
        defer { UserDefaults.standard.set(original, forKey: UserNotifier.enabledKey) }
        UserDefaults.standard.set(true, forKey: UserNotifier.enabledKey)
        var status: UNAuthorizationStatus = .denied
        var requests = 0
        let notifier = UserNotifier(readAuthorization: { status }, authorize: { requests += 1 })
        await notifier.requestAuthorizationIfEnabled()
        #expect(notifier.authorizationStatus == .denied)
        #expect(requests == 0)
        #expect(UserNotifier.isEnabled)
        status = .authorized
        await notifier.refreshAuthorization()
        #expect(notifier.authorizationStatus == .authorized)
        #expect(UserNotifier.isEnabled)
    }

    @Test func undeterminedRequestsOnceAndDisabledPreferenceDoesNotRequest() async {
        let original = UserDefaults.standard.object(forKey: UserNotifier.enabledKey)
        defer { UserDefaults.standard.set(original, forKey: UserNotifier.enabledKey) }
        UserDefaults.standard.set(false, forKey: UserNotifier.enabledKey)
        var status: UNAuthorizationStatus = .notDetermined
        var requests = 0
        let notifier = UserNotifier(readAuthorization: { status }, authorize: {
            requests += 1
            status = .authorized
        })
        await notifier.refreshAuthorization()
        #expect(notifier.authorizationStatus == .notDetermined)
        await notifier.requestAuthorizationIfEnabled()
        #expect(requests == 0)
        UserDefaults.standard.set(true, forKey: UserNotifier.enabledKey)
        await notifier.requestAuthorizationIfEnabled()
        await notifier.requestAuthorizationIfEnabled()
        #expect(requests == 1)
        #expect(notifier.authorizationStatus == .authorized)
    }
}
