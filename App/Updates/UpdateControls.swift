#if DIRECT_DISTRIBUTION
import SwiftUI

struct UpdateCommands: Commands {
    @ObservedObject var updates: DirectUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updates.isEnabled {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
        }
    }
}

struct UpdateSettingsSection: View {
    @ObservedObject var updates: DirectUpdater

    var body: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: { updates.automaticallyChecksForUpdates = $0 }))
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
        }
    }
}
#endif
