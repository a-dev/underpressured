import UnderpressuredApplication
import Foundation
import UnderpressuredCore

/// The Resize Rule kinds the popover offers (§4.1); the pixel value is separate.
public enum ResizeKind: CaseIterable, Sendable, Hashable {
    case none, maxWidth, maxHeight, maxLongEdge

    public var title: String {
        switch self {
        case .none: String(localized: "None", bundle: .module, comment: "Resize rule kind with no size limit")
        case .maxWidth: String(localized: "Max width", bundle: .module, comment: "Resize rule kind")
        case .maxHeight: String(localized: "Max height", bundle: .module, comment: "Resize rule kind")
        case .maxLongEdge: String(localized: "Max long edge", bundle: .module, comment: "Resize rule kind")
        }
    }

    public init(_ rule: ResizeRule) {
        switch rule {
        case .none: self = .none
        case .maxWidth: self = .maxWidth
        case .maxHeight: self = .maxHeight
        case .maxLongEdge: self = .maxLongEdge
        }
    }

    func rule(pixels: Int) -> ResizeRule {
        switch self {
        case .none: .none
        case .maxWidth: .maxWidth(.clamping(pixels))
        case .maxHeight: .maxHeight(.clamping(pixels))
        case .maxLongEdge: .maxLongEdge(.clamping(pixels))
        }
    }
}

/// Labels for the Preset popover and menus (§4.3).
public enum PresetStrings {
    public static let renameOperation = String(localized: "Rename Preset", bundle: .module, comment: "Undo operation for renaming a preset.")
    public static let qualityOperation = String(localized: "Change Preset Quality", bundle: .module, comment: "Undo operation for changing compression quality.")
    public static let name = String(localized: "Name", bundle: .module, comment: "Preset field label")
    public static let quality = String(localized: "Quality", bundle: .module, comment: "Preset field label")
    public static let lossless = String(localized: "Lossless", bundle: .module, comment: "Preset field label")
    public static let resizeRule = String(localized: "Resize Rule", bundle: .module, comment: "Preset field label")
    public static let outputFormat = String(localized: "Output Format", bundle: .module, comment: "Preset field label")
    public static let keepMetadata = String(localized: "Keep metadata", bundle: .module, comment: "Preset field label")
    public static let qualityHelp = String(localized: "Higher quality keeps more detail, while lower quality makes smaller files.", bundle: .module, comment: "Help text for preset quality")
    public static let losslessHelp = String(localized: "Images keep their original appearance. Resizing may change details. Saving as JPEG turns transparent areas white.", bundle: .module, comment: "Help text for lossless presets")
    public static let losslessQualityHelp = String(localized: "Quality is unused while Lossless is on.", bundle: .module, comment: "Help text for quality with lossless enabled")
    public static let keepMetadataHelp = String(localized: "Keeps EXIF, GPS and color profile data.", bundle: .module, comment: "Help text for metadata setting")
    public static let edit = String(localized: "Edit", bundle: .module, comment: "Preset menu action")
    public static let duplicate = String(localized: "Duplicate", bundle: .module, comment: "Preset menu action")
    public static let delete = String(localized: "Delete", bundle: .module, comment: "Preset menu action")
    public static let add = String(localized: "New Preset", bundle: .module, comment: "Preset menu action")
    public static let moveEarlier = String(localized: "Move Earlier", bundle: .module, comment: "Preset menu action")
    public static let moveLater = String(localized: "Move Later", bundle: .module, comment: "Preset menu action")
}

extension AppModel {
    /// The pixel value a Resize Rule gets when it is switched on from None.
    public static let defaultResizePixels = 2048

    // MARK: Activate

    /// Clicking a badge (§4.3).
    public func activatePreset(_ id: Preset.ID) {
        guard presets.preset(id: id) != nil else { return }
        endPresetEditingOperation()
        presetActivationRevision += 1
        presets.activate(id)
    }

    /// ⌘1 to ⌘9: 1-based position.
    public func activatePreset(position: Int) {
        guard presets.presets.indices.contains(position - 1) else { return }
        activatePreset(presets.presets[position - 1].id)
    }

    // MARK: Popover

    /// The pen, Edit in the context menu.
    public func editPreset(_ id: Preset.ID) {
        if presets.preset(id: id) != nil { editingPresetID = id }
    }

    /// ⌘,: opens the Active Preset's popover.
    public func editActivePreset() {
        editingPresetID = presets.activeID
    }

    /// Close the popover. `Preset.setName` already rejects empty names.
    public func closePresetEditor() {
        endPresetEditingOperation()
        editingPresetID = nil
    }

    // MARK: Edits (apply immediately, §4.3)

    /// Keep the badge name unchanged during editing so the popover anchor does not move.
    public func badgeTitle(_ preset: Preset) -> String {
        preset.id == editingPresetID ? nameAtEditStart ?? preset.displayName : preset.displayName
    }

    public func setPresetName(_ id: Preset.ID, _ name: String) {
        guard let proposedName = Preset.normalizedName(name) ?? (id == editingPresetID ? nameAtEditStart : nil) else { return }
        let original = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? presetEditingOperation?.before.preset(id: id) : nil
        mutatePresets(PresetStrings.renameOperation) { presets in
            if let original { presets.restoreName(id, from: original) }
            else { presets.rename(id, to: proposedName) }
        }
    }

    public func setPresetQuality(_ id: Preset.ID, _ quality: Int) {
        mutatePresets(String(localized: "Change Preset Quality", bundle: .module, comment: "Undo action name")) { presets in
            presets.setQuality(id, to: quality)
        }
    }

    public func setPresetLossless(_ id: Preset.ID, _ lossless: Bool) {
        mutatePresets(String(localized: "Change Preset Lossless", bundle: .module, comment: "Undo action name")) { presets in
            presets.setLossless(id, to: lossless)
        }
    }

    public func setPresetOutputFormat(_ id: Preset.ID, _ format: OutputFormat) {
        mutatePresets(String(localized: "Change Preset Format", bundle: .module, comment: "Undo action name")) { presets in
            presets.setOutputFormat(id, to: format)
        }
    }

    public func setPresetKeepMetadata(_ id: Preset.ID, _ keep: Bool) {
        mutatePresets(String(localized: "Change Preset Metadata", bundle: .module, comment: "Undo action name")) { presets in
            presets.setKeepMetadata(id, to: keep)
        }
    }

    /// Picks the Resize Rule kind and keeps the pixel value (2048 when there was none).
    public func setPresetResizeKind(_ id: Preset.ID, _ kind: ResizeKind) {
        mutatePresets(String(localized: "Change Preset Resize Rule", bundle: .module, comment: "Undo action name")) { presets in
            guard let preset = presets.preset(id: id) else { return }
            presets.setResizeRule(id, to: kind.rule(pixels: preset.resizeRule.pixels ?? Self.defaultResizePixels))
        }
    }

    /// Sets the pixel value; does nothing while the rule is None.
    public func setPresetResizePixels(_ id: Preset.ID, _ pixels: Int) {
        mutatePresets(String(localized: "Change Preset Size", bundle: .module, comment: "Undo action name")) { presets in
            guard let preset = presets.preset(id: id), preset.resizeRule.pixels != nil else { return }
            presets.setResizeRule(id, to: ResizeKind(preset.resizeRule).rule(pixels: pixels))
        }
    }

    /// Quality is greyed out while Lossless is on (§4.1).
    public func isQualityEnabled(_ id: Preset.ID) -> Bool {
        !(presets.preset(id: id)?.lossless ?? false)
    }

    // MARK: Add, duplicate, delete, reorder (§4.3)

    /// **+**: copies the Active Preset after the original, activates the copy and opens its popover.
    public func addPreset() {
        guard presets.canAdd else { return }
        endPresetEditingOperation()
        let name = presets.active.displayName
        mutatePresets(String(localized: "New Preset", bundle: .module, comment: "Undo action name")) {
            $0.duplicateActive(materializedName: name)
        }
        editingPresetID = presets.activeID
    }

    /// **+** and Duplicate are disabled once there are `PresetList.maxCount` Presets.
    public var canAddPreset: Bool { presets.canAdd }

    /// Duplicate in the context menu: the copy is activated.
    public func duplicatePreset(_ id: Preset.ID) {
        endPresetEditingOperation()
        let name = presets.preset(id: id)?.displayName
        mutatePresets(String(localized: "Duplicate Preset", bundle: .module, comment: "Undo action name")) {
            $0.duplicate(id, materializedName: name)
        }
    }

    /// Delete is disabled for the last Preset.
    public func canDeletePreset(_ id: Preset.ID) -> Bool {
        presets.presets.count > 1 && presets.preset(id: id) != nil
    }

    public func deletePreset(_ id: Preset.ID) {
        endPresetEditingOperation()
        let index = presets.presets.firstIndex { $0.id == id }
        mutatePresets(String(localized: "Delete Preset", bundle: .module, comment: "Undo action name")) { $0.delete(id) }
        if editingPresetID == id { editingPresetID = nil }
        if let index, presets.preset(id: id) == nil {
            presetFocusID = presets.presets[min(index, presets.presets.count - 1)].id
        }
    }

    public func canMovePresetEarlier(_ id: Preset.ID) -> Bool {
        guard let index = presets.presets.firstIndex(where: { $0.id == id }) else { return false }
        return index > 0
    }

    public func canMovePresetLater(_ id: Preset.ID) -> Bool {
        guard let index = presets.presets.firstIndex(where: { $0.id == id }) else { return false }
        return index < presets.presets.count - 1
    }

    public func movePresetEarlier(_ id: Preset.ID) {
        guard canMovePresetEarlier(id), let index = presets.presets.firstIndex(where: { $0.id == id }) else { return }
        movePreset(id, to: index - 1)
    }

    public func movePresetLater(_ id: Preset.ID) {
        guard canMovePresetLater(id), let index = presets.presets.firstIndex(where: { $0.id == id }) else { return }
        movePreset(id, to: index + 1)
    }

    /// Drag and drop: the dragged badge takes the place of the one it was dropped on.
    public func movePreset(_ id: Preset.ID, onto target: Preset.ID) {
        guard let index = presets.presets.firstIndex(where: { $0.id == target }) else { return }
        movePreset(id, to: index)
    }

    private func movePreset(_ id: Preset.ID, to index: Int) {
        guard let from = presets.presets.firstIndex(where: { $0.id == id }), from != index else { return }
        endPresetEditingOperation()
        mutatePresets(String(localized: "Move Preset", bundle: .module, comment: "Undo action name")) { $0.move(id, to: index) }
        presetFocusID = id
    }

    /// Coalesce a continuous control interaction without retaining no-op history.
    public func beginPresetEditingOperation(_ name: String) {
        endPresetEditingOperation()
        presetEditingOperation = (name, presets)
    }

    public func endPresetEditingOperation() {
        guard let operation = presetEditingOperation else { return }
        presetEditingOperation = nil
        registerPresetUndo(from: operation.before, to: presets, name: operation.name)
    }

    /// Settings → Reset Presets: replaces every Preset with the starters, first one active. Not undoable.
    public func resetPresets() {
        endPresetEditingOperation()
        editingPresetID = nil
        presets = .starter
        presetUndoManager?.removeAllActions(withTarget: self)
    }

    private func mutatePresets(_ name: String, _ change: (inout PresetList) -> Void) {
        if let operation = presetEditingOperation, operation.name != name { endPresetEditingOperation() }
        let before = presets
        var after = before
        change(&after)
        guard before != after else { return }
        presets = after
        if presetEditingOperation == nil { registerPresetUndo(from: before, to: after, name: name) }
    }

    private func registerPresetUndo(from before: PresetList, to after: PresetList, name: String) {
        guard before != after, let manager = presetUndoManager else { return }
        let revision = presetActivationRevision
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: self) { model in
            model.restorePresets(before, activationRevision: revision, name: name)
        }
        manager.setActionName(name)
        manager.endUndoGrouping()
        presetUndoRevision += 1
    }

    private func restorePresets(_ state: PresetList, activationRevision: Int, name: String) {
        let previous = presets
        var restored = state
        // An explicit activation, including clicking the automatic fallback, wins.
        if presetActivationRevision != activationRevision {
            restored.activate(previous.activeID)
        }
        presets = restored
        if previous.presets.map(\.id) != restored.presets.map(\.id) {
            presetFocusID = restored.presets.first { previous.preset(id: $0.id) == nil }?.id ?? restored.activeID
        }
        if let id = editingPresetID, restored.preset(id: id) == nil { closePresetEditor() }
        registerPresetUndo(from: previous, to: restored, name: name)
    }
}
