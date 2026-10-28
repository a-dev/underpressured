import UnderpressuredCore
import Foundation

/// Scans URLs into Items outside the main actor. Tests can supply a closure.
public typealias Intake = @Sendable (_ dropped: [URL], _ exportFolder: URL?, _ isActive: @Sendable (URL) -> Bool) -> ScanResult

/// Everything remembered across launches (spec §4.4). The Item list is not part of it.
public struct AppSettings: Sendable, Hashable {
    public var presets: PresetList
    public var destination: DestinationSettings

    public init(presets: PresetList, destination: DestinationSettings) {
        self.presets = presets
        self.destination = destination
    }

    /// First launch: the starter Presets with Balanced active, Replace originals.
    public static var initial: AppSettings {
        AppSettings(presets: .starter, destination: .initial)
    }
}

/// Loads and saves `AppSettings` (5.11 supplies the UserDefaults one).
@MainActor
public protocol SettingsStore: AnyObject {
    /// nil when nothing usable was saved; the model then starts from `AppSettings.initial`.
    func load() -> AppSettings?
    func save(_ settings: AppSettings)
}

/// macOS notifications (spec §3.5); 5.8 supplies the UserNotifications one.
@MainActor
public protocol Notifier: AnyObject {
    /// Called once, when the first Batch starts.
    func requestPermission()
    /// Posts `text` unless permission was denied.
    func post(_ text: String)
}

/// Prevents idle system sleep while the Queue runs (spec §3.7); 5.10 supplies the IOKit one.
@MainActor
public protocol SleepPreventer: AnyObject {
    func setPreventing(_ preventing: Bool, reason: String)
}

/// Stand-ins used until the real services are wired, and by tests.
@MainActor
public final class InMemorySettingsStore: SettingsStore {
    public private(set) var saved: AppSettings?
    public init(_ saved: AppSettings? = nil) { self.saved = saved }
    public func load() -> AppSettings? { saved }
    public func save(_ settings: AppSettings) { saved = settings }
}

@MainActor
public final class SilentNotifier: Notifier {
    public init() {}
    public func requestPermission() {}
    public func post(_ text: String) {}
}

@MainActor
public final class NoSleepPreventer: SleepPreventer {
    public init() {}
    public func setPreventing(_ preventing: Bool, reason: String) {}
}
