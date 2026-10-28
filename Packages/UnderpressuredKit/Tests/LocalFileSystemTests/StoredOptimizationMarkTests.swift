import Foundation
import Testing
@testable import LocalFileSystem
import UnderpressuredCore

@Suite struct StoredOptimizationMarkTests {
    static let settings = EffectiveSettings(
        quality: 80, lossless: false, resizeRule: .maxLongEdge(2048), keepMetadata: true)
    static let date = Date(timeIntervalSince1970: 1_700_000_000.123)
    static let v1Fixture = #"{"format":{"jpeg":{}},"modifiedMs":1700000000123,"settings":{"keepMetadata":true,"lossless":false,"quality":80,"resizeRule":{"maxLongEdge":{"_0":2048}}},"size":1234,"v":1}"#

    static func mark(
        settings: EffectiveSettings = settings, format: WritableFormat = .jpeg,
        size: Int64 = 1234, date: Date = date
    ) -> OptimizationMark {
        OptimizationMark(settings: settings, outputFormat: format, size: size, modificationDate: date)
    }

    @Test func storedMark_roundTripsDomainFactsAndMillisecondPrecision() throws {
        let original = Self.mark()
        let decoded = try #require(StoredOptimizationMark.decode(StoredOptimizationMark.encode(original)))
        #expect(decoded == original)
        #expect(decoded.modificationDate == Date(timeIntervalSince1970: 1_700_000_000.123))
    }

    @Test func storedMark_roundTripsEveryResizeRuleAndFormat() {
        for rule in [ResizeRule.none, .maxWidth(100), .maxHeight(200), .maxLongEdge(300)] {
            for format in WritableFormat.allCases {
                let mark = Self.mark(
                    settings: EffectiveSettings(
                        quality: 1, lossless: true, resizeRule: rule, keepMetadata: false),
                    format: format)
                #expect(StoredOptimizationMark.decode(StoredOptimizationMark.encode(mark)) == mark)
            }
        }
    }

    @Test func storedMark_encodesEveryResizeAndFormatAlternativeInV1Shape() throws {
        let rules: [(ResizeRule, String)] = [
            (.none, #"{"none":{}}"#),
            (.maxWidth(100), #"{"maxWidth":{"_0":100}}"#),
            (.maxHeight(200), #"{"maxHeight":{"_0":200}}"#),
            (.maxLongEdge(300), #"{"maxLongEdge":{"_0":300}}"#)
        ]
        for (rule, expectedRule) in rules {
            for format in WritableFormat.allCases {
                let mark = Self.mark(settings: EffectiveSettings(
                    quality: 1, lossless: true, resizeRule: rule, keepMetadata: false), format: format)
                let object = try JSONSerialization.jsonObject(with: StoredOptimizationMark.encode(mark)) as! [String: Any]
                let settings = object["settings"] as! [String: Any]
                let actualRule = try JSONSerialization.data(withJSONObject: settings["resizeRule"]!)
                let expectedFormat = format == .jpeg ? #"{"jpeg":{}}"# : #"{"png":{}}"#
                let actualFormat = try JSONSerialization.data(withJSONObject: object["format"]!)
                #expect(String(decoding: actualRule, as: UTF8.self) == expectedRule)
                #expect(String(decoding: actualFormat, as: UTF8.self) == expectedFormat)
            }
        }
    }

    @Test func storedMark_rejectsMultipleOrMalformedEnumAlternatives() throws {
        let original = String(decoding: StoredOptimizationMark.encode(Self.mark()), as: UTF8.self)
        let multipleFormats = original.replacingOccurrences(of: #""format":{"jpeg":{}}"#, with: #""format":{"jpeg":{},"png":{}}"#)
        let malformedFormat = original.replacingOccurrences(of: #""format":{"jpeg":{}}"#, with: #""format":{"jpeg":1}"#)
        let multipleRules = original.replacingOccurrences(of: #""resizeRule":{"maxLongEdge":{"_0":2048}}"#, with: #""resizeRule":{"none":{},"maxLongEdge":{"_0":2048}}"#)
        let malformedRule = original.replacingOccurrences(of: #""resizeRule":{"maxLongEdge":{"_0":2048}}"#, with: #""resizeRule":{"none":10}"#)

        for json in [multipleFormats, malformedFormat, multipleRules, malformedRule] {
            #expect(StoredOptimizationMark.decode(Data(json.utf8)) == nil)
        }
    }

    @Test func storedMark_readsAndWritesTheOriginalV1Fixture() throws {
        let bytes = Data(Self.v1Fixture.utf8)
        let decoded = try #require(StoredOptimizationMark.decode(bytes))
        #expect(decoded == Self.mark())
        #expect(StoredOptimizationMark.encode(decoded) == bytes)
    }

    @Test func storedMark_rejectsAChangeAcrossTheHalfMillisecondBoundary() throws {
        let mark = Self.mark(date: Date(timeIntervalSince1970: 1_793_148_449.435))
        let decoded = try #require(StoredOptimizationMark.decode(StoredOptimizationMark.encode(mark)))
        let filesystemDate = Date(timeIntervalSince1970: 1_793_148_449.4355)
        let attributes = FileAttributes(kind: .file, size: 1234, modificationDate: filesystemDate)

        // The two dates fall in different rounded millisecond buckets.
        #expect(!decoded.isValid(for: attributes))
    }

    @Test func storedMark_roundTripsBoundaryDatesWithoutChangingValidity() throws {
        for epoch in [0.0, 978_307_200.0, 1_700_000_000.0, 1_793_148_449.0, -1_000_000_000.0] {
            for offset in [0.000_499, 0.000_5, 0.000_501] {
                let boundary = Date(timeIntervalSince1970: epoch + offset)
                for interval in [boundary.timeIntervalSinceReferenceDate.nextDown,
                                 boundary.timeIntervalSinceReferenceDate,
                                 boundary.timeIntervalSinceReferenceDate.nextUp] {
                    let date = Date(timeIntervalSinceReferenceDate: interval)
                    let original = Self.mark(date: date)
                    let attributes = FileAttributes(kind: .file, size: 1234, modificationDate: date)
                    var restored = original
                    for _ in 0..<3 {
                        restored = try #require(StoredOptimizationMark.decode(StoredOptimizationMark.encode(restored)))
                        #expect(restored.isValid(for: attributes), "epoch=\(epoch), interval=\(interval), original=\(date.timeIntervalSince1970), restored=\(restored.modificationDate.timeIntervalSince1970)")
                    }
                    for delta in [0.000_1, 0.001, -0.001] {
                        let changed = FileAttributes(kind: .file, size: 1234, modificationDate: date.addingTimeInterval(delta))
                        #expect(restored.isValid(for: changed) == original.isValid(for: changed))
                    }
                    #expect(!restored.isValid(for: FileAttributes(kind: .file, size: 1235, modificationDate: date)))
                }
            }
        }
    }

    @Test func storedMark_roundTripsActualFileDates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mark-date-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("fixture".utf8).write(to: url)
        let access = LocalFileAccess()
        for offset in [0.000_499, 0.000_5, 0.000_501] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_793_148_449 + offset)], ofItemAtPath: url.path)
            let attributes = try access.attributes(of: url)
            var mark = Self.mark(size: attributes.size, date: attributes.modificationDate)
            for _ in 0..<3 {
                try access.setOptimizationMark(mark, at: url)
                mark = try #require(access.markedOutput(at: url)?.mark)
                #expect(mark.isValid(for: try access.attributes(of: url)))
            }
        }
    }

    @Test func storedMark_rejectsUnknownVersionBeforeDecodingShape() throws {
        let json = String(decoding: StoredOptimizationMark.encode(Self.mark()), as: UTF8.self)
        let future = json.replacingOccurrences(of: "\"v\":1", with: "\"v\":2")
        #expect(StoredOptimizationMark.decode(Data(future.utf8)) == nil)
        #expect(StoredOptimizationMark.decode(Data(#"{"v":99,"something":["new"]}"#.utf8)) == nil)
    }

    @Test func storedMark_rejectsInvalidData() {
        #expect(StoredOptimizationMark.decode(Data()) == nil)
        #expect(StoredOptimizationMark.decode(Data([0xFF, 0x00, 0x12])) == nil)
        #expect(StoredOptimizationMark.decode(Data("{}".utf8)) == nil)
        #expect(StoredOptimizationMark.decode(Data(#"{"v":1}"#.utf8)) == nil)
    }

    @Test func storedMark_keepsExistingAttributeName() {
        #expect(StoredOptimizationMark.attributeName == "app.underpressured.mark")
    }
}
