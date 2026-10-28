import Foundation

/// Named compression and resize settings. `PresetList` owns validation and editing rules.
public struct Preset: Sendable, Hashable, Identifiable {
    /// Stable identity for built-in presets. Persisted independently of their localized labels.
    public enum StarterID: String, Sendable, Hashable, CaseIterable {
        case balanced
        case web
        case screenshots
        case small
    }

    public let id: UUID
    public internal(set) var name: String
    public internal(set) var starterID: StarterID?
    public internal(set) var quality: Quality
    public var lossless: Bool
    public internal(set) var resizeRule: ResizeRule
    public var keepMetadata: Bool
    public var outputFormat: OutputFormat

    public init(
        id: UUID = UUID(), name: String, quality: Quality, lossless: Bool,
        resizeRule: ResizeRule, keepMetadata: Bool, outputFormat: OutputFormat = .original,
        starterID: StarterID? = nil
    ) {
        self.id = id
        self.name = Self.normalizedName(name) ?? Self.fallbackName
        self.starterID = starterID
        self.quality = quality
        self.lossless = lossless
        self.resizeRule = resizeRule
        self.keepMetadata = keepMetadata
        self.outputFormat = outputFormat
    }

    /// A duplicate has a new identity and a materialized, validated name.
    public func duplicated(name: String) -> Preset {
        Preset(name: name, quality: quality, lossless: lossless, resizeRule: resizeRule,
               keepMetadata: keepMetadata, outputFormat: outputFormat)
    }

    /// The Preset without its name: what a Batch and an Optimization mark record (§7.1, §7.5).
    public var settings: EffectiveSettings {
        EffectiveSettings(
            quality: quality, lossless: lossless, resizeRule: resizeRule, keepMetadata: keepMetadata)
    }
}

/// Limits an image's dimensions. Images are only ever scaled down (spec §4.1).
public enum ResizeRule: Sendable, Hashable {
    case none
    case maxWidth(PixelLimit)
    case maxHeight(PixelLimit)
    case maxLongEdge(PixelLimit)
}

/// The compression and resize settings that decide an Item's output, with no Preset name.
public struct EffectiveSettings: Sendable, Hashable {
    public var quality: Quality
    public var lossless: Bool
    public var resizeRule: ResizeRule
    public var keepMetadata: Bool

    public init(quality: Quality, lossless: Bool, resizeRule: ResizeRule, keepMetadata: Bool) {
        self.quality = quality
        self.lossless = lossless
        self.resizeRule = resizeRule
        self.keepMetadata = keepMetadata
    }
}
