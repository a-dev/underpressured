import Foundation

extension Preset {
    /// The Quality range (spec §4.1).
    public static let qualityRange = 0...100
    /// The longest a Preset name may be, in characters (spec §4.1).
    public static let maxNameLength = 70
    /// The name given to a stored Preset whose name is empty and has no previous name to return to.
    public static let fallbackName = "Preset"

    /// Trim whitespace and limit the name to 70 characters. Return nil if empty to retain the previous name.
    public static func normalizedName(_ proposed: String) -> String? {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cut = String(trimmed.prefix(maxNameLength))
        return cut.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keep the previous name if blank. Limit names to 70 characters. Duplicate names are allowed.
    public mutating func setName(_ proposed: String) {
        if let name = Preset.normalizedName(proposed) {
            self.name = name
            starterID = nil
        }
    }

    /// Sets Quality, clamped to 0...100.
    public mutating func setQuality(_ proposed: Int) {
        quality = .clamping(proposed)
    }

    /// Sets the Resize Rule; a pixel value below 1 becomes 1.
    public mutating func setResizeRule(_ proposed: ResizeRule) {
        resizeRule = proposed
    }

    public var isValid: Bool { Self.normalizedName(name) == name && Self.qualityRange.contains(quality.rawValue) && resizeRule.isValid }

    /// The Presets a first launch (or Reset Presets) starts with; Balanced JPEG is first and active (spec §4.2).
    public static var starters: [Preset] {
        [
            Preset(
                name: "Balanced JPEG", quality: 80, lossless: false, resizeRule: .none,
                keepMetadata: false, outputFormat: .jpeg, starterID: .balanced),
            Preset(
                name: "Web", quality: 80, lossless: false, resizeRule: .maxLongEdge(2048),
                keepMetadata: false, starterID: .web),
            Preset(
                name: "Small", quality: 60, lossless: false, resizeRule: .maxLongEdge(1080),
                keepMetadata: false, starterID: .small),
            Preset(
                name: "Screenshots PNG", quality: 70, lossless: false, resizeRule: .none,
                keepMetadata: true, outputFormat: .png, starterID: .screenshots)
        ]
    }
}

extension ResizeRule {
    /// The pixel value, or nil for `.none`.
    public var pixels: Int? {
        switch self {
        case .none: nil
        case .maxWidth(let value), .maxHeight(let value), .maxLongEdge(let value): value.rawValue
        }
    }

    public var isValid: Bool { pixels.map { $0 > 0 } ?? true }
}
