import AppKit
import UnderpressuredApplication

/// Asks for the folder that a converted file needs beside its dropped original, or for an Export folder
/// that the sandbox no longer grants (§6). Outside the App Sandbox every folder the user can write is writable,
/// so no panel appears.
@MainActor
final class FolderAccessPanel: FolderAccess {
    /// `access(2)` applies the App Sandbox: a granted file does not make its folder writable.
    func canCreateFiles(in folder: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: folder.path)
    }

    func requestAccess(to folder: URL, for purpose: FolderAccessPurpose) async {
        // A missing folder has nothing to grant; processing reports it as Export folder unavailable.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Grant Access", bundle: .main, comment: "Action button in the folder panel that grants access to the folder of a dropped file.")
        panel.message = switch purpose {
        case .siblingOutputs:
            String(
                localized: "To save converted images next to the originals, Underpressured needs access to “\(folder.lastPathComponent)”.",
                bundle: .main,
                comment: "Message in the folder panel shown before converting dropped files with Replace Originals. Placeholder is a folder name.")
        case .exportFolder:
            String(
                localized: "To save copies to your Export folder, Underpressured needs access to “\(folder.lastPathComponent)” again.",
                bundle: .main,
                comment: "Message in the folder panel shown when the remembered Export folder is no longer accessible, for example after moving from the direct download. Placeholder is a folder name.")
        }
        guard await panel.begin() == .OK else { return }
        // Reading the chosen URL consumes the sandbox extension for it; until then the grant stays in the panel.
        // The caller checks `canCreateFiles(in:)` again, so choosing another folder or cancelling is safe.
        _ = panel.url
    }
}
