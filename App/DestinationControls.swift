import UnderpressuredApplication
import AppKit
import AppModel
import SwiftUI

/// Controls replacement, Trash, and the Export folder.
struct DestinationControls: View {
    @Bindable var model: AppModel
    var selectFolder: @MainActor () -> URL? = Self.selectExportFolder
    @State private var pickerRevision = 0

    var body: some View {
        FlowLayout(spacing: 12, lineSpacing: 6) {
            Picker("Destination", selection: Binding(
                get: { model.destination.kind },
                set: { mode in
                    chooseMode(mode)
                }
            )) {
                Text("Replace Originals").tag(DestinationSettings.Kind.replaceOriginals)
                Text("Export Copies").tag(DestinationSettings.Kind.exportFolder)
            }
            .id(pickerRevision)
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Destination")
            .fixedSize()

            if model.showsMoveToTrash {
                Toggle("Move original to Trash", isOn: Binding(
                    get: { model.destination.moveToTrash },
                    set: { model.setMoveToTrash($0) }))
            } else if let folder = model.destination.exportFolder {
                Menu {
                    Button("Choose Another Folder…", action: pickFolder)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    Divider()
                    Button("Forget Folder") { model.forgetExportFolder() }
                } label: {
                    Label("Export folder: \(FileText.name(folder.lastPathComponent))", systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .leading)
                }
                .accessibilityIdentifier("export-folder")
                .help(folder.path)
                .accessibilityLabel("Export folder")
                .accessibilityValue(folder.path)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("destination-controls")
        .accessibilityLabel("Destination")
    }

    func chooseMode(_ mode: DestinationSettings.Kind) {
        if mode == .replaceOriginals { model.chooseReplaceOriginals() }
        else if !model.chooseRememberedExportFolder() {
            pickFolder()
            // Recreate the native picker after cancellation even when the model did not change.
            pickerRevision += 1
        }
    }

    func pickFolder() {
        if let url = selectFolder() { model.chooseExportFolder(url) }
    }

    private static func selectExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", bundle: .main, comment: "Action button in the native export-folder chooser.")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
