import AppKit
import UnderpressuredApplication

/// Asks for the folder that a converted file needs beside its dropped original (§6).
/// Outside the App Sandbox every folder the user can write is writable, so no panel appears.
@MainActor
final class FolderAccessPanel: FolderAccess {
    /// `access(2)` applies the App Sandbox: a granted file does not make its folder writable.
    func canCreateFiles(in folder: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: folder.path)
    }

    func requestAccess(to folder: URL) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Grant Access", bundle: .main, comment: "Action button in the folder panel that grants access to the folder of a dropped file.")
        panel.message = String(
            localized: "To save converted images next to the originals, Underpressured needs access to “\(folder.lastPathComponent)”.",
            bundle: .main,
            comment: "Message in the folder panel shown before converting dropped files with Replace Originals. Placeholder is a folder name.")
        _ = await panel.begin()
    }
}
