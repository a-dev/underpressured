import Foundation
import Testing

@testable import UnderpressuredCore

@Suite struct OptimizationMarkTests {
    static let settings = EffectiveSettings(
        quality: 80, lossless: false, resizeRule: .maxLongEdge(2048), keepMetadata: true)
    static let date = Date(timeIntervalSince1970: 1_700_000_000.123)

    static func mark(
        settings: EffectiveSettings = settings, format: WritableFormat = .jpeg,
        size: Int64 = 1234, date: Date = date
    ) -> OptimizationMark {
        OptimizationMark(settings: settings, outputFormat: format, size: size, modificationDate: date)
    }

    static func attributes(size: Int64 = 1234, date: Date = date) -> FileAttributes {
        FileAttributes(kind: .file, size: size, modificationDate: date)
    }

    @Test func mark_spec7_5_invalid_bySize() {
        #expect(!Self.mark().isValid(for: Self.attributes(size: 1235)))
    }

    @Test func mark_spec7_5_invalid_byDate() {
        #expect(!Self.mark().isValid(for: Self.attributes(date: Self.date.addingTimeInterval(1))))
        #expect(!Self.mark().isValid(for: Self.attributes(date: Self.date.addingTimeInterval(0.01))))
    }

    @Test func mark_spec7_5_valid_dateComparedToTheMillisecond() {
        let nanosecondNoise = Self.date.addingTimeInterval(0.0000002)
        #expect(Self.mark().isValid(for: Self.attributes(date: nanosecondNoise)))
    }

    @Test func mark_spec7_5_matches_sameSettingsUnderDifferentPresetName() {
        let a = Preset(name: "Web", quality: 80, lossless: false, resizeRule: .maxLongEdge(2048), keepMetadata: true)
        let b = Preset(name: "Renamed", quality: 80, lossless: false, resizeRule: .maxLongEdge(2048), keepMetadata: true)
        let m = Self.mark(settings: a.settings)
        #expect(m.matches(settings: b.settings, outputFormat: .jpeg))
    }

    @Test func mark_spec7_5_matches_differsByEachSetting() {
        let m = Self.mark()
        let s = Self.settings
        var other = s; other.quality = Quality.clamping(79)
        #expect(!m.matches(settings: other, outputFormat: .jpeg))
        other = s; other.lossless = true
        #expect(!m.matches(settings: other, outputFormat: .jpeg))
        other = s; other.resizeRule = .maxWidth(2048)
        #expect(!m.matches(settings: other, outputFormat: .jpeg))
        other = s; other.keepMetadata = false
        #expect(!m.matches(settings: other, outputFormat: .jpeg))
        #expect(!m.matches(settings: s, outputFormat: .png))
        #expect(m.matches(settings: s, outputFormat: .jpeg))
    }
}
