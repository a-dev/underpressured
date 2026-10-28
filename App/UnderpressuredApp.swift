import AppKit
import AppModel
import SwiftUI
import UnderpressuredCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `UnderpressuredApp` once the window appears; nil means nothing can be running.
    var model: AppModel?
    /// Holds Dock drops and Open With URLs that arrive before the window attaches the model (§3.6).
    let router = OpenRouter()
    #if DIRECT_DISTRIBUTION
    let updates = DirectUpdater()
    #endif

    /// Dock drop, Open With and Finder double-click all arrive here.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { await router.open(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting during a run asks first; confirming cancels and then quits (§3.7).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DIRECT_DISTRIBUTION
        if updates.postponeTermination({ NSApp.reply(toApplicationShouldTerminate: $0) }) {
            return .terminateLater
        }
        #endif
        guard let model, case .confirm(let message) = model.quitDecision else { return .terminateNow }
        let alert = Self.quitAlert(message: message)
        guard Self.runQuitAlert(alert) == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            await model.cancelForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Return confirms the requested quit; Escape and Command-period keep the run alive.
    static func quitAlert(message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "Cancel and Quit", bundle: .main))
        let keepRunning = alert.addButton(withTitle: String(localized: "Keep Running", bundle: .main))
        keepRunning.keyEquivalent = "\u{1b}"
        return alert
    }

    static func runQuitAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard alert.window.isKeyWindow, handleQuitAlertKey(event, alert: alert) else { return event }
            return nil
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        return alert.runModal()
    }

    static func handleQuitAlertKey(_ event: NSEvent, alert: NSAlert) -> Bool {
        if event.charactersIgnoringModifiers == ".",
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            alert.buttons[1].performClick(nil)
            return true
        }
        return false
    }
}

@main
struct UnderpressuredApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppWiring.makeModel()

    var body: some Scene {
        Window(String(localized: "Underpressured", bundle: .main), id: "main") {
            MainWindow(model: model)
                .onAppear {
                    appDelegate.model = model
                    #if DIRECT_DISTRIBUTION
                    appDelegate.updates.start(model: model)
                    #endif
                    Task { await appDelegate.router.attach(model) }
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Underpressured") {
                    let credits = NSMutableAttributedString()
                    if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") {
                        credits.append(NSAttributedString(
                            string: String(localized: "Acknowledgements", bundle: .main),
                            attributes: [.link: url]))
                    }
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
                }
            }
            CommandGroup(replacing: .help) {
                Button("Underpressured Help") {
                    NSWorkspace.shared.open(AppInfo.documentationURL)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
            PresetUndoCommands(model: model)
            #if DIRECT_DISTRIBUTION
            UpdateCommands(updates: appDelegate.updates)
            #endif
            CommandGroup(replacing: .newItem) {
                Button("Open…") { showOpenPanel(model: model) }
                    .keyboardShortcut("o")
                Button("Cancel") { Task { await model.cancel() } }
                    .keyboardShortcut(".")
                    .disabled(!model.isRunning)
            }
            CommandMenu("Presets") {
                ForEach(Array(model.presets.presets.enumerated()), id: \.element.id) { index, preset in
                    PresetMenuItem(
                        model: model, preset: preset, position: index + 1,
                        isActive: model.presets.activeID == preset.id)
                }
                Divider()
                Button(PresetStrings.add) { model.addPreset() }
                    .disabled(!model.canAddPreset)
                Button("Edit Active Preset…") { model.editActivePreset() }
                Divider()
                Button(PresetStrings.moveEarlier) { model.movePresetEarlier(model.presets.activeID) }
                    .disabled(!model.canMovePresetEarlier(model.presets.activeID))
                Button(PresetStrings.moveLater) { model.movePresetLater(model.presets.activeID) }
                    .disabled(!model.canMovePresetLater(model.presets.activeID))
            }
        }
        Settings {
            #if DIRECT_DISTRIBUTION
            SettingsView(model: model).environmentObject(appDelegate.updates)
            #else
            SettingsView(model: model)
            #endif
        }
    }
}

private struct PresetMenuItem: View {
    var model: AppModel
    let preset: Preset
    let position: Int
    let isActive: Bool

    private var selection: Binding<Bool> {
        Binding(
            get: { isActive },
            set: { _ in model.activatePreset(preset.id) })
    }

    var body: some View {
        if position <= 9 {
            Toggle(preset.displayName, isOn: selection)
                .keyboardShortcut(KeyEquivalent(Character("\(position)")))
        } else {
            Toggle(preset.displayName, isOn: selection)
        }
    }
}
