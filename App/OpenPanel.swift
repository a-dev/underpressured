import AppKit
import AppModel

/// ⌘O: picks files and folders and opens them like a window drop (§3.6).
@MainActor
func showOpenPanel(model: AppModel) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    let urls = panel.urls
    Task { await model.open(urls) }
}
