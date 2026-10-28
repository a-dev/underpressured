import UnderpressuredApplication
import Foundation
import UnderpressuredCore

/// The versioned extended-attribute representation of an OptimizationMark.
/// All schema and compatibility decisions stay in the file-system adapter.
struct StoredOptimizationMark {
    static let attributeName = "app.underpressured.mark"
    private static let currentVersion = 1

    private struct VersionProbe: Decodable {
        var v: Int
    }

    private struct Payload: Codable {
        var v: Int
        var settings: StoredSettings
        var format: StoredWritableFormat
        var size: Int64
        var modifiedMs: Int64
    }

    static func encode(_ mark: OptimizationMark) -> Data {
        let payload = Payload(
            v: currentVersion, settings: StoredSettings(mark.settings), format: StoredWritableFormat(mark.outputFormat), size: mark.size,
            modifiedMs: milliseconds(mark.modificationDate))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding these plain value types cannot fail.
        return (try? encoder.encode(payload)) ?? Data()
    }

    /// Return nil for invalid data or unknown versions. Check the version before decoding the payload.
    static func decode(_ data: Data) -> OptimizationMark? {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data),
            probe.v == currentVersion,
            let payload = try? decoder.decode(Payload.self, from: data)
        else { return nil }
        return OptimizationMark(
            settings: payload.settings.domainValue, outputFormat: payload.format.domainValue, size: payload.size,
            modificationDate: Date(timeIntervalSince1970: Double(payload.modifiedMs) / 1000))
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private struct StoredSettings: Codable {
        var keepMetadata: Bool
        var lossless: Bool
        var quality: Int
        var resizeRule: StoredResizeRule

        init(_ value: EffectiveSettings) {
            keepMetadata = value.keepMetadata
            lossless = value.lossless
            quality = value.quality.rawValue
            resizeRule = StoredResizeRule(value.resizeRule)
        }

        var domainValue: EffectiveSettings {
            EffectiveSettings(quality: .clamping(quality), lossless: lossless,
                              resizeRule: resizeRule.domainValue, keepMetadata: keepMetadata)
        }
    }

    private enum StoredWritableFormat: Codable {
        case jpeg
        case png

        init(_ value: WritableFormat) {
            switch value {
            case .jpeg: self = .jpeg
            case .png: self = .png
            }
        }

        var domainValue: WritableFormat {
            switch self {
            case .jpeg: .jpeg
            case .png: .png
            }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CaseKey.self)
            guard container.allKeys.count == 1, let key = container.allKeys.first else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown writable format"))
            }
            switch key {
            case .jpeg:
                _ = try container.nestedContainer(keyedBy: EmptyKey.self, forKey: key)
                self = .jpeg
            case .png:
                _ = try container.nestedContainer(keyedBy: EmptyKey.self, forKey: key)
                self = .png
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CaseKey.self)
            switch self {
            case .jpeg:
                _ = container.nestedContainer(keyedBy: EmptyKey.self, forKey: .jpeg)
            case .png:
                _ = container.nestedContainer(keyedBy: EmptyKey.self, forKey: .png)
            }
        }

        private enum CaseKey: String, CodingKey { case jpeg, png }
        private enum EmptyKey: String, CodingKey { case unused }
    }

    private enum StoredResizeRule: Codable {
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
}
