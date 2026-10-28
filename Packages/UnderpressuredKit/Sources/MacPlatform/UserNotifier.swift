import UnderpressuredCore
import UnderpressuredApplication
import Foundation
import Observation
import UserNotifications

/// Requests notification permission once. If denied, completion appears only in the banner.
@MainActor
@Observable
public final class UserNotifier: Notifier {
    public static let enabledKey = "notificationsEnabled"

    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    public private(set) var authorizationStatus: UNAuthorizationStatus?
    @ObservationIgnored private let readAuthorization: () async -> UNAuthorizationStatus
    @ObservationIgnored private let authorize: () async -> Void

    public convenience init() {
        self.init(readAuthorization: {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }, authorize: {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        })
    }

    init(readAuthorization: @escaping () async -> UNAuthorizationStatus, authorize: @escaping () async -> Void) {
        self.readAuthorization = readAuthorization
        self.authorize = authorize
    }

    public func refreshAuthorization() async {
        authorizationStatus = await readAuthorization()
    }

    public func requestAuthorizationIfEnabled() async {
        guard Self.isEnabled else { return }
        await refreshAuthorization()
        if Self.isEnabled && authorizationStatus == .notDetermined { await authorize() }
        await refreshAuthorization()
    }

    public func requestPermission() {
        guard Self.isEnabled else { return }
        Task {
            await requestAuthorizationIfEnabled()
        }
    }

    public func post(_ text: String) {
        guard Self.isEnabled else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard Self.isEnabled, [.authorized, .provisional].contains(settings.authorizationStatus) else { return }
            let content = UNMutableNotificationContent()
            content.title = "Underpressured"
            content.body = text
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
