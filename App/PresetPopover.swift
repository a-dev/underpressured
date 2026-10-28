import AppModel
import SwiftUI
import UnderpressuredCore

/// The popover with a Preset's fields; edits apply immediately (§4.3).
struct PresetPopover: View {
    @Bindable var model: AppModel
    let id: Preset.ID
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    /// Delete after the popover closes. Removing its anchor while open hangs AppKit.
    @State private var deleteOnClose = false

    private var preset: Preset { model.presets.preset(id: id) ?? model.presets.active }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 20) {
            row(PresetStrings.name) {
                TextField(PresetStrings.name, text: $name)
                    .accessibilityLabel(PresetStrings.name)
                    .focused($nameFocused)
                    .onChange(of: nameFocused) {
                        if nameFocused { model.beginPresetEditingOperation(PresetStrings.renameOperation) }
                        else { model.endPresetEditingOperation() }
                    }
                    .labelsHidden()
                    .frame(minWidth: 190, maxWidth: .infinity)
                    .onChange(of: name) {
                        name = String(name.prefix(Preset.maxNameLength))
                        if name != preset.displayName { model.setPresetName(id, name) }
                    }
            }
            row(PresetStrings.outputFormat) {
                Picker(PresetStrings.outputFormat, selection: Binding(
                    get: { preset.outputFormat }, set: { model.setPresetOutputFormat(id, $0) })
                ) {
                    ForEach(model.outputFormatChoices, id: \.self) { Text($0.title) }
                }
                .labelsHidden()
                .fixedSize()
            }
            row(PresetStrings.quality) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        // No `step:`: on macOS it draws a tick mark per step.
                        Slider(
                            value: Binding(
                                get: { Double(preset.quality.rawValue) },
                                set: { model.setPresetQuality(id, Int($0.rounded())) }),
                            in: 0...100,
                            onEditingChanged: { editing in
                                if editing { model.beginPresetEditingOperation(PresetStrings.qualityOperation) }
                                else { model.endPresetEditingOperation() }
                            })
                        .accessibilityLabel(PresetStrings.quality)
                        .accessibilityValue(model.isQualityEnabled(id)
                            ? preset.quality.rawValue.formatted() : String(localized: "\(preset.quality.rawValue.formatted()), unused while Lossless is on", bundle: .main, comment: "Spoken disabled quality value. Placeholder is a formatted quality number, 0 to 100."))
                        Text(verbatim: preset.quality.rawValue.formatted()).monospacedDigit().frame(width: 28, alignment: .trailing)
                            .foregroundStyle(model.isQualityEnabled(id) ? .primary : .tertiary)
                            .accessibilityHidden(true)
                    }
                    .disabled(!model.isQualityEnabled(id))
                    help(model.isQualityEnabled(id) ? PresetStrings.qualityHelp : PresetStrings.losslessQualityHelp)
                }
            }
            row(nil) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(PresetStrings.lossless, isOn: Binding(
                        get: { preset.lossless }, set: { model.setPresetLossless(id, $0) }))
                    help(PresetStrings.losslessHelp).padding(.leading, 20)
                }
            }
            row(PresetStrings.resizeRule) {
                HStack(spacing: 10) {
                    Picker(PresetStrings.resizeRule, selection: Binding(
                        get: { ResizeKind(preset.resizeRule) },
                        set: { model.setPresetResizeKind(id, $0) })
                    ) {
                        ForEach(ResizeKind.allCases, id: \.self) { Text($0.title) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("px", value: Binding(
                        get: { preset.resizeRule.pixels ?? AppModel.defaultResizePixels },
                        set: { model.setPresetResizePixels(id, $0) }), format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(width: 64)
                        .accessibilityLabel(AccessibilityText.resizePixels)
                        .disabled(preset.resizeRule.pixels == nil)
                    Text("px").foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            row(nil) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(PresetStrings.keepMetadata, isOn: Binding(
                        get: { preset.keepMetadata }, set: { model.setPresetKeepMetadata(id, $0) }))
                    help(PresetStrings.keepMetadataHelp).padding(.leading, 20)
                }
            }
            Divider()
            HStack {
                Button(PresetStrings.duplicate, systemImage: "plus.square.on.square") {
                    model.duplicatePreset(id)
                }
                .disabled(!model.canAddPreset)
                Spacer()
                Button(PresetStrings.delete, systemImage: "trash", role: .destructive) {
                    deleteOnClose = true
                    model.closePresetEditor()
                }
                .disabled(!model.canDeletePreset(id))
            }
        }
        .padding(14)
        .frame(width: 480)
        .environment(\.layoutDirection, AppLocalization.layoutDirection)
        .onAppear { name = preset.displayName }
        .onChange(of: preset.displayName) { if !nameFocused { name = preset.displayName } }
        .onDisappear {
            model.endPresetEditingOperation()
            if deleteOnClose { model.deletePreset(id) }
        }
    }

    /// Grid columns share the widest translated label; help wraps within the control column.
    private func row(_ label: String?, @ViewBuilder content: () -> some View) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label ?? "").fixedSize(horizontal: false, vertical: true).accessibilityHidden(label == nil)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func help(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
