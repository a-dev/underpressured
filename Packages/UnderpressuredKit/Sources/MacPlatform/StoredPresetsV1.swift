import UnderpressuredCore
import Foundation

/// The version 1 UserDefaults representation for Preset order and fields.
public struct StoredPresetsV1: Sendable, Hashable, Codable {
    public static let version = 1

    private var storedPresets: [StoredPresetV1]
    public var activePresetID: UUID

    public var presets: [Preset] { storedPresets.map(\.preset) }

    public init(presets: [Preset], activePresetID: UUID) {
        storedPresets = presets.map(StoredPresetV1.init)
        self.activePresetID = activePresetID
    }

    public enum StorageError: Error, Equatable, Sendable {
        case unsupportedVersion(Int)
        case noPresets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.version else { throw StorageError.unsupportedVersion(version) }
        let decoded = try container.decode([StoredPresetV1].self, forKey: .presets)
        guard !decoded.isEmpty else { throw StorageError.noPresets }
        let active = try container.decode(UUID.self, forKey: .activePresetID)
        let list = try PresetList.restoring(presets: decoded.map(\.preset), activeID: active)
        storedPresets = list.presets.map(StoredPresetV1.init)
        activePresetID = list.activeID
    }

    private enum CodingKeys: String, CodingKey { case version, presets, activePresetID }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(storedPresets, forKey: .presets)
        try container.encode(activePresetID, forKey: .activePresetID)
    }
}

/// Version 1 fields are primitives; domain values are constructed only after decoding.
private struct StoredPresetV1: Sendable, Hashable, Codable {
    let id: UUID
    let name: String
    let starterID: StoredStarterIDV1?
    let quality: Int
    let lossless: Bool
    let resizeRule: StoredResizeRuleV1
    let keepMetadata: Bool
    let outputFormat: StoredOutputFormatV1

    init(_ preset: Preset) {
        id = preset.id
        name = preset.name
        starterID = preset.starterID.map(StoredStarterIDV1.init)
        quality = preset.quality.rawValue
        lossless = preset.lossless
        resizeRule = StoredResizeRuleV1(preset.resizeRule)
        keepMetadata = preset.keepMetadata
        outputFormat = StoredOutputFormatV1(preset.outputFormat)
    }

    private enum CodingKeys: String, CodingKey { case id, name, starterID, quality, lossless, resizeRule, keepMetadata, outputFormat }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        starterID = try container.decodeIfPresent(StoredStarterIDV1.self, forKey: .starterID)
        quality = try container.decode(Int.self, forKey: .quality)
        lossless = try container.decode(Bool.self, forKey: .lossless)
        resizeRule = try container.decode(StoredResizeRuleV1.self, forKey: .resizeRule)
        keepMetadata = try container.decode(Bool.self, forKey: .keepMetadata)
        outputFormat = try container.decodeIfPresent(StoredOutputFormatV1.self, forKey: .outputFormat) ?? .original
    }

    var preset: Preset {
        Preset(id: id, name: name, quality: .clamping(quality), lossless: lossless,
               resizeRule: resizeRule.domainValue, keepMetadata: keepMetadata,
               outputFormat: outputFormat.domainValue,
               starterID: starterID?.domainValue)
    }
}

private enum StoredStarterIDV1: String, Sendable, Hashable, Codable {
    case balanced
    case web
    case screenshots
    case small

    init(_ value: Preset.StarterID) {
        switch value {
        case .balanced: self = .balanced
        case .web: self = .web
        case .screenshots: self = .screenshots
        case .small: self = .small
        }
    }

    var domainValue: Preset.StarterID {
        switch self {
        case .balanced: .balanced
        case .web: .web
        case .screenshots: .screenshots
        case .small: .small
        }
    }
}

private enum StoredOutputFormatV1: Sendable, Hashable, Codable {
    case original
    case jpeg
    case png

    init(_ value: OutputFormat) {
        switch value {
        case .original: self = .original
        case .jpeg: self = .jpeg
        case .png: self = .png
        }
    }

    var domainValue: OutputFormat {
        switch self {
        case .original: .original
        case .jpeg: .jpeg
        case .png: .png
        }
    }
}

private enum StoredResizeRuleV1: Sendable, Hashable, Codable {
    case none
    case maxWidth(Int)
    case maxHeight(Int)
    case maxLongEdge(Int)

    private enum CaseKey: String, CodingKey, CaseIterable { case none, maxWidth, maxHeight, maxLongEdge }
    private enum ValueKey: String, CodingKey { case value = "_0" }

    init(_ value: ResizeRule) {
        switch value {
        case .none: self = .none
        case let .maxWidth(limit): self = .maxWidth(limit.rawValue)
        case let .maxHeight(limit): self = .maxHeight(limit.rawValue)
        case let .maxLongEdge(limit): self = .maxLongEdge(limit.rawValue)
        }
    }

    var domainValue: ResizeRule {
        switch self {
        case .none: .none
        case let .maxWidth(value): .maxWidth(.clamping(value))
        case let .maxHeight(value): .maxHeight(.clamping(value))
        case let .maxLongEdge(value): .maxLongEdge(.clamping(value))
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CaseKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown resize rule"))
        }
        switch key {
        case .none:
            _ = try container.nestedContainer(keyedBy: ValueKey.self, forKey: key)
            self = .none
        case .maxWidth: self = .maxWidth(try container.nestedContainer(keyedBy: ValueKey.self, forKey: key).decode(Int.self, forKey: .value))
        case .maxHeight: self = .maxHeight(try container.nestedContainer(keyedBy: ValueKey.self, forKey: key).decode(Int.self, forKey: .value))
        case .maxLongEdge: self = .maxLongEdge(try container.nestedContainer(keyedBy: ValueKey.self, forKey: key).decode(Int.self, forKey: .value))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .none:
            _ = container.nestedContainer(keyedBy: ValueKey.self, forKey: .none)
        case let .maxWidth(value):
            var nested = container.nestedContainer(keyedBy: ValueKey.self, forKey: .maxWidth)
            try nested.encode(value, forKey: .value)
        case let .maxHeight(value):
            var nested = container.nestedContainer(keyedBy: ValueKey.self, forKey: .maxHeight)
            try nested.encode(value, forKey: .value)
        case let .maxLongEdge(value):
            var nested = container.nestedContainer(keyedBy: ValueKey.self, forKey: .maxLongEdge)
            try nested.encode(value, forKey: .value)
        }
    }
}
