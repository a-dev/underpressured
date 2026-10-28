import AppKit
import AppModel
import SwiftUI
import UnderpressuredCore

/// Preset badges and **+** (§4.3, §3.1). Badges that don't fit wrap onto further rows.
struct PresetBar: View {
    @Bindable var model: AppModel
    @FocusState private var focusedPreset: Preset.ID?
    @State private var contentHeight: CGFloat = 28
    @State private var rowHeight: CGFloat = 28

    private var maximumHeight: CGFloat { rowHeight * 3 + 6 * 2 + 3 * 2 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                badges
                    .padding(3)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, maximumHeight))
            .scrollDisabled(contentHeight <= maximumHeight)
            .task {
                await Task.yield()
                focusedPreset = model.presets.presets.first?.id
            }
            .onChange(of: focusedPreset) {
                if let focusedPreset { proxy.scrollTo(focusedPreset, anchor: .center) }
            }
            .onChange(of: model.presetFocusID) { focusedPreset = model.presetFocusID }
        }
    }

    private var badges: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(model.presets.presets) { preset in
                PresetBadge(model: model, preset: preset, focus: $focusedPreset)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
                    .id(preset.id)
            }
            Button { model.addPreset() } label: {
                Image(systemName: "plus").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!model.canAddPreset)
            .help(PresetStrings.add)
            .accessibilityLabel(AccessibilityText.addPreset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// SwiftUI mirrors these layout coordinates in RTL; do not reverse them a second time.
/// Wrap from the leading edge when the next subview does not fit.
struct FlowLayout: Layout {
    var spacing: Double
    var lineSpacing: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * Double(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width = 0.0
        var height = 0.0
    }

    private func rows(width: Double, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if next > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Edit, Duplicate, Delete: the badge's context menu.
struct PresetActions: View {
    @Bindable var model: AppModel
    let id: Preset.ID

    var body: some View {
        Button(PresetStrings.edit) { model.editPreset(id) }
        Button(PresetStrings.duplicate) { model.duplicatePreset(id) }
            .disabled(!model.canAddPreset)
        Divider()
        Button(PresetStrings.moveEarlier) { model.movePresetEarlier(id) }
            .disabled(!model.canMovePresetEarlier(id))
        Button(PresetStrings.moveLater) { model.movePresetLater(id) }
            .disabled(!model.canMovePresetLater(id))
        Divider()
        Button(PresetStrings.delete, role: .destructive) { model.deletePreset(id) }
            .disabled(!model.canDeletePreset(id))
    }
}

/// One capsule. Clicking it activates it; clicking the Active Preset opens its popover.
struct PresetBadge: View {
    @Bindable var model: AppModel
    let preset: Preset
    var focus: FocusState<Preset.ID?>.Binding
    private var isKeyboardFocused: Bool { focus.wrappedValue == preset.id }
    @AccessibilityFocusState private var isAccessibilityFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    private var isActive: Bool { model.presets.activeID == preset.id }
    private var id: Preset.ID { preset.id }

    private func moveAccessibly(earlier: Bool) {
        guard earlier ? model.canMovePresetEarlier(id) : model.canMovePresetLater(id) else { return }
        if earlier { model.movePresetEarlier(id) } else { model.movePresetLater(id) }
        Task { @MainActor in
            await Task.yield()
            guard let index = model.presets.presets.firstIndex(where: { $0.id == id }),
                  let window = NSApp.mainWindow else { return }
            isAccessibilityFocused = true
            NSAccessibility.post(
                element: window, notification: .announcementRequested,
                userInfo: [.announcement: AccessibilityText.presetPosition(
                    name: model.presets.presets[index].displayName, position: index + 1, count: model.presets.presets.count),
                           .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    private func press() {
        if isActive { model.editPreset(id) } else { model.activatePreset(id) }
    }

    var body: some View {
        Button(action: press) {
            Text(model.badgeTitle(preset)).lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused(focus, equals: preset.id)
        // `.focusable()` on a plain-style Button takes focus but never fires the action from the keyboard.
        .onKeyPress(keys: [.space, .return]) { _ in
            press()
            return .handled
        }
        .focusEffectDisabled()
        .accessibilityFocused($isAccessibilityFocused)
        .accessibilityLabel(AccessibilityText.presetBadge(name: preset.displayName))
        .accessibilityValue(AccessibilityText.presetBadgeValue(isActive: isActive) ?? "")
        .accessibilityHint(AccessibilityText.presetBadgeHint)
        .foregroundStyle(isActive ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary)
        .background {
            Capsule().fill(isActive ? Color.accentColor : .clear)
            Capsule().fill((isActive ? Color.white : Color.accentColor)
                .opacity(isKeyboardFocused ? (isActive ? 0.18 : 0.05) : 0))
        }
        .overlay(Capsule().strokeBorder(
            isKeyboardFocused ? Color(nsColor: .keyboardFocusIndicatorColor) : Color.accentColor,
            lineWidth: contrast == .increased ? 2 : 1))
        .contentShape(Capsule())
        .accessibilityAction(named: AccessibilityText.editPreset(name: preset.displayName)) { model.editPreset(id) }
        .accessibilityActions {
            if model.canMovePresetEarlier(id) {
                Button(PresetStrings.moveEarlier) { moveAccessibly(earlier: true) }
            }
            if model.canMovePresetLater(id) {
                Button(PresetStrings.moveLater) { moveAccessibly(earlier: false) }
            }
        }
        .contextMenu { PresetActions(model: model, id: id) }
        .draggable(id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            model.movePreset(dragged, onto: id)
            return true
        }
        .popover(isPresented: Binding(
            get: { model.editingPresetID == id },
            set: { if !$0 { model.closePresetEditor() } })
        ) {
            PresetPopover(model: model, id: id)
        }
    }
}
