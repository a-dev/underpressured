import MacPlatform
import AppKit
import AppModel
import SwiftUI
import UserNotifications

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            SupportSettingsView()
                .tabItem { Label("Support", systemImage: "questionmark.circle") }
        }
        .frame(width: 560, height: 390)
        .environment(\.layoutDirection, AppLocalization.layoutDirection)
    }
}

struct GeneralSettingsView: View {
    let model: AppModel
    @State private var confirmingPresetReset = false
    @State private var notifier: UserNotifier
    @State private var notificationSettingsFailed = false
    #if DIRECT_DISTRIBUTION
    @EnvironmentObject private var updates: DirectUpdater
    #endif
    @AppStorage(UserNotifier.enabledKey) private var notificationsEnabled = true
    #if DEBUG
    @State private var developerLanguage: String = {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: bundleID)?["AppleLanguages"] as? [String],
              let language = languages.first,
              ["en", "es", "pt-BR", "de", "fr", "ar", "ja", "zh-Hans"].contains(language) else { return "system" }
        return language
    }()
    #endif

    init(model: AppModel, notifier: UserNotifier = UserNotifier()) {
        self.model = model
        _notifier = State(initialValue: notifier)
    }

    static var resolvedLanguage: String {
        let identifier = AppLocalization.languageIdentifier
        return Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
    }

    var body: some View {
        Form {
            Section("Language") {
                Text("This app is translated into English, Spanish, Brazilian Portuguese, German, French, Arabic, Japanese, and Simplified Chinese. Change the language in System Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Notifications") {
                Toggle("Notify when processing finishes", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) {
                        if notificationsEnabled { notifier.requestPermission() }
                    }
                if notifier.authorizationStatus == .denied {
                    Text("Notifications are blocked in System Settings. Choose Notifications, then Underpressured, to allow them.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Notification Settings…") { openNotificationSettings() }
                } else if notificationsEnabled && notifier.authorizationStatus == .notDetermined {
                    Text("Notification permission has not been requested yet.")
                        .foregroundStyle(.secondary)
                    Button("Allow Notifications…") { notifier.requestPermission() }
                }
            }
            Section("Presets") {
                LabeledContent {
                    Button("Reset Presets…") { confirmingPresetReset = true }
                } label: {
                    Text("Replace all presets with the defaults.")
                }
            }
            #if DEBUG
            Section("Developer") {
                Picker("App language", selection: $developerLanguage) {
                    Text("System default").tag("system")
                    ForEach(["en", "es", "pt-BR", "de", "fr", "ar", "ja", "zh-Hans"], id: \.self) { identifier in
                        Text(verbatim: Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier)
                            .tag(identifier)
                    }
                }
                .onChange(of: developerLanguage) {
                    if developerLanguage == "system" {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([developerLanguage], forKey: "AppleLanguages")
                    }
                }
                Text("Quit and reopen the app to apply the language change.")
                    .foregroundStyle(.secondary)
            }
            #endif
            #if DIRECT_DISTRIBUTION
            if updates.isEnabled { UpdateSettingsSection(updates: updates) }
            #endif
        }
        .formStyle(.grouped)
        .task { await notifier.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifier.refreshAuthorization() }
        }
        .alert("Could not open System Settings", isPresented: $notificationSettingsFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Open System Settings and choose Notifications, then Underpressured.")
        }
        .confirmationDialog("Reset all presets?", isPresented: $confirmingPresetReset) {
            Button("Reset Presets", role: .destructive) { model.resetPresets() }
        } message: {
            Text("Your presets will be removed and replaced with the defaults. You can't undo this.")
        }
    }

    private func openNotificationSettings() {
        let settings = NSWorkspace.shared
        // The pane URL is handled by System Settings; fall back to opening the application.
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
           settings.open(url) { return }
        guard let url = settings.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
            notificationSettingsFailed = true
            return
        }
        notificationSettingsFailed = !settings.open(url)
    }
}

struct SupportSettingsView: View {
    @Environment(\.openURL) private var openURL
    @State private var failedURL: URL?

    var body: some View {
        Form {
            Section("Get Help") {
                LabeledContent("Documentation") {
                    Button { open(AppInfo.documentationURL) } label: { Text(verbatim: "underpressured.app") }
                        .buttonStyle(.link)
                        .focusable()
                }
                LabeledContent("Email") {
                    Button(AppInfo.supportEmail) { open(AppInfo.supportURL) }
                        .buttonStyle(.link)
                        .focusable()
                        .accessibilityLabel("Email support at \(AppInfo.supportEmail)")
                }
                Button("Report an Issue on GitHub…") { open(AppInfo.issuesURL) }
                    .buttonStyle(.link)
                    .focusable()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Report a mistranslation or offer a translation review through GitHub issues or pull requests.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Contribute a Translation…") { open(AppInfo.translationContributionURL) }
                        .buttonStyle(.link)
                        .focusable()
                }
                Button("Privacy Policy") { open(AppInfo.privacyPolicyURL) }
                    .buttonStyle(.link)
                    .focusable()
            }
        }
        .formStyle(.grouped)
        // AppKit focuses the first focusable link when the window opens; start with no focus instead.
        .onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }
        .alert("Could not open the link", isPresented: Binding(
            get: { failedURL != nil }, set: { if !$0 { failedURL = nil } })
        ) {
            Button("OK", role: .cancel) { failedURL = nil }
        } message: {
            Text(failedURL?.absoluteString ?? "")
        }
    }

    private func open(_ url: URL) {
        // LaunchServices calls the completion off the main queue; a main-actor closure would trap there.
        let failedURL = $failedURL
        openURL(url) { @Sendable accepted in
            guard !accepted else { return }
            Task { @MainActor in failedURL.wrappedValue = url }
        }
    }
}
