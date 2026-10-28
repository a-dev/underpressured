import UnderpressuredApplication
import Foundation
import UnderpressuredCore

/// VoiceOver wording for the main window (spec §3). Views only attach these strings.
public enum AccessibilityText {
    // MARK: Header

    /// "Web preset": the badge's label.
    public static func presetBadge(name: String) -> String { String(localized: "\(name) preset", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.") }
    /// "active" for the Active Preset, else nil: the badge's value.
    public static func presetBadgeValue(isActive: Bool) -> String? { isActive ? String(localized: "active", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.") : nil }
    /// "Web preset, active" as VoiceOver speaks the label and value together.
    public static func presetBadgeSpoken(name: String, isActive: Bool) -> String {
        isActive
            ? String(localized: "\(name) preset, active", bundle: .module, comment: "Spoken active preset badge. Placeholder is the preset display name.")
            : presetBadge(name: name)
    }
    public static let presetBadgeHint = String(localized: "Makes it the Active Preset; on the Active Preset, opens its settings", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.")
    /// "Edit Web preset": the badge's Edit action.
    public static func editPreset(name: String) -> String { String(localized: "Edit \(name) preset", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.") }
    public static func presetPosition(name: String, position: Int, count: Int) -> String {
        String(localized: "\(name) preset, position \(position) of \(count)", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.")
    }
    public static let addPreset = String(localized: "Add preset", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.")

    /// "Destination: Replace originals": keeps the visible title inside the label (Voice Control).
    public static func destinationMenu(title: String) -> String { String(localized: "Destination: \(title)", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.") }

    // MARK: Preset popover

    public static let resizePixels = String(localized: "Resize Rule pixels", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.")

    // MARK: Empty state

    public static let emptyStateHint = String(localized: "Or press Command O to choose files", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.")

    // MARK: Item list

    public static let clearList = String(localized: "Clear list", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.")
    public static let processing = String(localized: "Processing", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.")
    /// Row actions on an openable row.
    public static let openAction = String(localized: "Open", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.")
    public static let quickLookAction = String(localized: "Quick Look", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.")
    public static let showInFinderAction = String(localized: "Show in Finder", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.")

    // MARK: Banner

    /// "2 failed" button: label.
    public static func filterButton(title: String) -> String { String(localized: "Show only \(title)", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.") }
    /// "showing" while the filter is on, else nil.
    public static func filterButtonValue(isOn: Bool) -> String? { isOn ? String(localized: "showing", bundle: .module, comment: "Accessibility label, value, hint, or action. Interpolated names and titles are user data or localized labels.") : nil }

    /// Join complete spoken phrases without parsing visible punctuation or digits.
    static func joined(_ first: String, _ second: String) -> String {
        String(localized: "\(first), \(second)", bundle: .module, comment: "Join two complete spoken phrases. Both placeholders are localized speech or user data.")
    }

    static func row(item: Item, state: String, folderPath: String?) -> String {
        let name = item.source.lastPathComponent
        let location = folderPath.map {
            String(localized: "\(name) in \($0)", bundle: .module, comment: "Spoken image location. Filename and relative folder path are user data.")
        } ?? name
        var speech = joined(location, state)
        switch item.state {
        case .finished(.optimized(let savings, let notes, _)):
            let sizes = String(localized: "\(Presentation.size(savings.originalBytes)) to \(Presentation.size(savings.newBytes))", bundle: .module, comment: "Spoken original and optimized file sizes, both preformatted byte sizes.")
            speech = joined(joined(speech, sizes), sizeChange(savings))
            for note in notes { speech = joined(speech, note.spokenMessage) }
        case .finished(.skipped(let reason, let notes, _)):
            speech = joined(speech, reason.message)
            for note in notes { speech = joined(speech, note.spokenMessage) }
        case .finished(.failed(let reason)):
            speech = joined(speech, reason.message)
        default: break
        }
        return speech
    }

    static func sizeChange(_ savings: Savings) -> String {
        let percent = Presentation.roundedPercent(savings)
        if percent == 0 { return String(localized: "no size change", bundle: .module, comment: "Spoken size comparison when rounded percentage is zero.") }
        if savings.bytes < 0 {
            return String(localized: "\(percent.formatted()) percent larger", bundle: .module, comment: "Spoken image growth; placeholder is a whole percentage without the percent sign.")
        }
        return String(localized: "\(percent.formatted()) percent smaller", bundle: .module, comment: "Spoken image savings; placeholder is a whole percentage without the percent sign.")
    }
}

extension ItemRow {
    public var accessibilityLabel: String {
        spokenLabel ?? AccessibilityText.joined(name, stateText)
    }
}

extension FooterState {
    public var accessibilityLabel: String? { spokenLabel }
}

extension Banner {
    public var accessibilityLabel: String { spokenLabel ?? text }
}
