import AppKit
import AppModel
import QuickLook
import QuickLookUI
import SwiftUI

/// Groups Items by drop with Finder selection, Open, and Quick Look controls.
/// Open and Quick Look use `AppModel.openableURLs`.
struct ItemListView: View {
    @Bindable var model: AppModel
    var openFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var revealFiles: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    @State private var previewURL: URL?
    // Keep the presented candidates available while SwiftUI dismisses the preview.
    @State private var previewCandidates: [URL] = []
    /// Hands ↑/↓ from the open Quick Look panel back to the list (`forwardArrowsToList`).
    @State private var arrowForwarder: Any?
    @FocusState private var isFocused: Bool
    @State private var focusAnchor = NSView()

    private var previewURLs: [URL] { model.openableURLs(for: model.selection) }

    var body: some View {
        let availableURLs = Set(model.openableURLs(for: Set(model.rows.map(\.id))))
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        ItemRowView(row: row, isOpenable: row.openURL.map(availableURLs.contains) ?? false,
                                    open: { open([row.id]) }, quickLook: { previewRow(row.id) },
                                    reveal: { reveal([row.id]) })
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            // Separators start under the text, like the old inset Divider.
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    }
                } header: {
                    SectionHeaderView(section: section)
                        .listRowInsets(EdgeInsets())
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .focused($isFocused)
        .background(ListFocusAnchor(view: focusAnchor).frame(width: 0, height: 0))
        .contextMenu(forSelectionType: ItemRow.ID.self, menu: { ids in
            let unavailable = model.openableURLs(for: ids).isEmpty
            Button(AccessibilityText.openAction) { open(ids) }
                .disabled(unavailable)
            Button(AccessibilityText.quickLookAction) { preview(ids) }
                .disabled(unavailable)
            Button(AccessibilityText.showInFinderAction) { reveal(ids) }
                .disabled(unavailable)
        }, primaryAction: open)
        .onKeyPress(.space) { toggleQuickLook() }
        .quickLookPreview($previewURL, in: previewCandidates)
        .onChange(of: previewURL == nil) { _, closed in forwardArrowsToList(!closed) }
        // ↑/↓ moved the selection: the preview follows, as in Finder.
        .onChange(of: model.selection) { _, selection in
            // A click selects without taking focus from a preset badge; Space must reach the list.
            if !selection.isEmpty, !isFocused { isFocused = true }
            let urls = model.openableURLs(for: selection)
            guard let current = previewURL else { return }
            guard !urls.isEmpty else { previewURL = nil; return }
            previewCandidates = urls
            if !urls.contains(current) { previewURL = urls.first }
        }
        // Admission can focus an unoccupied window, but never an editor or another control.
        .onAppear { Task { @MainActor in requestIntakeFocus() } }
        .onDisappear { forwardArrowsToList(false) }
        .onChange(of: model.intakeAdmissionRevision) { _, _ in requestIntakeFocus() }
    }

    private func requestIntakeFocus() {
        guard model.editingPresetID == nil, let window = focusAnchor.window else { return }
        let responder = window.firstResponder
        guard isFocused || responder == nil || responder === window || responder === window.contentView else { return }
        isFocused = true
    }

    private func open(_ ids: Set<ItemRow.ID>) {
        let urls = model.openableURLs(for: ids)
        guard !urls.isEmpty else { return }
        urls.forEach(openFile)
    }

    private func toggleQuickLook() -> KeyPress.Result {
        if previewURL != nil {
            previewURL = nil
            return .handled
        }
        // Nothing to show: let Space through.
        guard let first = previewURLs.first else { return .ignored }
        previewCandidates = previewURLs
        previewURL = first
        return .handled
    }

    private func reveal(_ ids: Set<ItemRow.ID>) {
        let urls = model.openableURLs(for: ids)
        guard !urls.isEmpty else { return }
        revealFiles(urls)
    }

    private func previewRow(_ id: ItemRow.ID) {
        guard let url = model.openableURLs(for: [id]).first else { return }
        if !model.selection.contains(id) { model.selection = [id] }
        previewCandidates = previewURLs
        previewURL = url
    }

    /// Context menus supply the clicked row or selected set; preview follows that same set.
    private func preview(_ ids: Set<ItemRow.ID>) {
        let urls = model.openableURLs(for: ids)
        guard let first = urls.first else { return }
        model.selection = ids
        previewCandidates = urls
        previewURL = first
    }

    /// Forward Quick Look arrow keys to the list, then update the preview.
    private func forwardArrowsToList(_ forward: Bool) {
        if let arrowForwarder { NSEvent.removeMonitor(arrowForwarder) }
        arrowForwarder = nil
        guard forward else { return }
        arrowForwarder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let upOrDown = event.specialKey == .upArrow || event.specialKey == .downArrow
            guard upOrDown, event.window is QLPreviewPanel,
                  let list = NSApp.mainWindow?.firstResponder else { return event }
            list.keyDown(with: event)
            return nil
        }
    }
}

/// The sticky header of one drop: its folder and the Preset it ran with.
private struct SectionHeaderView: View {
    let section: ItemSection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.title3).foregroundStyle(.blue)
            Text(verbatim: FileText.path(section.title))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            Text(verbatim: FileText.name(section.presetName))
                .font(.caption).fontWeight(.medium)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .overlay(Capsule().stroke(Color.accentColor))
            Text(section.outputFormatLabel).font(.caption).foregroundStyle(.secondary)
        }
        // Extra room on top separates one drop from the rows of the drop above.
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
        // The List draws the pinned header background. Another background creates a visible seam.
        .accessibilityElement(children: .combine)
    }
}

private struct ItemRowView: View {
    let row: ItemRow
    let isOpenable: Bool
    let open: () -> Void
    let quickLook: () -> Void
    let reveal: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private var secondary: AnyShapeStyle {
        contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private var savingsColor: Color {
        if row.isGrowth { return .red }
        if row.isReduction { return .green }
        return .primary
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: FileText.name(row.name)).lineLimit(1).truncationMode(.middle)
                    if let convertedExtension = row.convertedExtension {
                        Text(verbatim: "→ \(convertedExtension)")
                            .foregroundStyle(secondary)
                            .fixedSize()
                    }
                    if let folder = row.folderPath {
                        Text(verbatim: FileText.path(folder)).foregroundStyle(secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                // Always present so every row has the same height.
                Text(row.detail ?? " ").font(.caption).foregroundStyle(secondary).lineLimit(1)
                    .truncationMode(.tail).help(row.detail ?? "")
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if row.isProcessing {
                    if reduceMotion {
                        Image(systemName: "ellipsis.circle").foregroundStyle(secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                if let issue = row.issueText {
                    Text(issue).foregroundStyle(secondary)
                }
            }
            if let sizes = row.sizesText {
                Text(sizes).foregroundStyle(secondary).monospacedDigit()
            }
            if let savings = row.savingsText {
                Text(savings)
                    .monospacedDigit()
                    .foregroundStyle(savingsColor)
                    .fontWeight(row.isGrowth ? .semibold : .regular)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .modifier(OpenActions(isOpenable: isOpenable, open: open, quickLook: quickLook, reveal: reveal))
    }
}

/// File actions in the VoiceOver actions rotor, on available rows only.
private struct OpenActions: ViewModifier {
    let isOpenable: Bool
    let open: () -> Void
    let quickLook: () -> Void
    let reveal: () -> Void

    func body(content: Content) -> some View {
        if isOpenable {
            content
                .accessibilityAction(named: AccessibilityText.openAction, open)
                .accessibilityAction(named: AccessibilityText.quickLookAction, quickLook)
                .accessibilityAction(named: AccessibilityText.showInFinderAction, reveal)
        } else {
            content
        }
    }
}

/// Supplies the containing native window without retaining it in view state.
private struct ListFocusAnchor: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
