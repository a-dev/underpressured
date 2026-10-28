import Foundation
import Testing
import UnderpressuredCore
import MacPlatform

@Suite struct PresetStorageTests {
    @Test func legacyPresetDefaultsOutputFormatAndPreservesFields() throws {
        let id = UUID(uuidString: "A4E7D054-B381-4E5C-92F0-E8227464DE81")!
        let json = """
        {"version":1,"activePresetID":"\(id.uuidString)","presets":[{"id":"\(id.uuidString)","name":"Web","quality":37,"lossless":true,"resizeRule":{"maxWidth":{"_0":720}},"keepMetadata":true}]}
        """
        let stored = try JSONDecoder().decode(StoredPresetsV1.self, from: Data(json.utf8))
        let preset = try #require(stored.presets.first)
        #expect(stored.activePresetID == id)
        #expect(preset.name == "Web" && preset.starterID == nil)
        #expect(preset.quality == 37 && preset.lossless && preset.resizeRule == .maxWidth(720))
        #expect(preset.keepMetadata && preset.outputFormat == .original)
    }

    @Test func currentPayloadRoundTripKeepsFieldSchemaAndOrder() throws {
        let first = Preset(name: "Current JPEG", quality: 73, lossless: false, resizeRule: .maxWidth(960), keepMetadata: true, outputFormat: .jpeg, starterID: .web)
        let second = Preset(name: "Current PNG", quality: 41, lossless: true, resizeRule: .none, keepMetadata: false, outputFormat: .png)
        let stored = StoredPresetsV1(presets: [first, second], activePresetID: second.id)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any]
        let values = encoded?["presets"] as? [[String: Any]]
        #expect(encoded?["version"] as? Int == 1)
        #expect(encoded?["activePresetID"] as? String == second.id.uuidString)
        #expect(values?.count == 2)
        #expect(values?[0]["starterID"] as? String == "web")
        #expect((values?[0]["outputFormat"] as? [String: Any])?.keys.first == "jpeg")
        #expect((values?[1]["outputFormat"] as? [String: Any])?.keys.first == "png")
        #expect(try JSONDecoder().decode(StoredPresetsV1.self, from: JSONEncoder().encode(stored)) == stored)
    }

    @Test func everyStoredEnumAlternativeKeepsItsV1Shape() throws {
        let rules: [(ResizeRule, String)] = [
            (.none, #"{"none":{}}"#),
            (.maxWidth(720), #"{"maxWidth":{"_0":720}}"#),
            (.maxHeight(640), #"{"maxHeight":{"_0":640}}"#),
            (.maxLongEdge(1200), #"{"maxLongEdge":{"_0":1200}}"#)
        ]
        let formats: [(OutputFormat, String)] = [
            (.original, #"{"original":{}}"#),
            (.jpeg, #"{"jpeg":{}}"#),
            (.png, #"{"png":{}}"#)
        ]

        for (rule, expectedRule) in rules {
            for (format, expectedFormat) in formats {
                let preset = Preset(name: "Mapping", quality: 37, lossless: false,
                                   resizeRule: rule, keepMetadata: true, outputFormat: format)
                let stored = StoredPresetsV1(presets: [preset], activePresetID: preset.id)
                let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as! [String: Any]
                let value = (json["presets"] as! [[String: Any]])[0]
                let actualRule = try JSONSerialization.data(withJSONObject: value["resizeRule"]!)
                let actualFormat = try JSONSerialization.data(withJSONObject: value["outputFormat"]!)
                #expect(String(decoding: actualRule, as: UTF8.self) == expectedRule)
                #expect(String(decoding: actualFormat, as: UTF8.self) == expectedFormat)
                let restored = try JSONDecoder().decode(StoredPresetsV1.self, from: JSONEncoder().encode(stored))
                #expect(restored.presets[0].resizeRule == rule && restored.presets[0].outputFormat == format)
            }
        }
    }

    @Test func starterIdentifiersKeepTheirLiteralV1Strings() throws {
        let cases: [(Preset.StarterID, String)] = [
            (.balanced, "balanced"), (.web, "web"), (.screenshots, "screenshots"), (.small, "small")
        ]
        for (starter, expected) in cases {
            let preset = Preset(name: "Starter", quality: 80, lossless: false,
                                resizeRule: .none, keepMetadata: true, starterID: starter)
            let stored = StoredPresetsV1(presets: [preset], activePresetID: preset.id)
            let data = try JSONEncoder().encode(stored)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let values = try #require(json["presets"] as? [[String: Any]])
            #expect(values.first?["starterID"] as? String == expected)
            #expect(try JSONDecoder().decode(StoredPresetsV1.self, from: data).presets.first?.starterID == starter)
        }
    }

    @Test func literalCurrentFixturePreservesScalarFieldsIdentityOrderAndActivePreset() throws {
        let first = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let second = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let third = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
        let json = """
        {"version":1,"activePresetID":"\(second.uuidString)","presets":[
          {"id":"\(first.uuidString)","name":"Current JPEG","starterID":"web","quality":73,"lossless":false,"resizeRule":{"maxWidth":{"_0":960}},"keepMetadata":true,"outputFormat":{"jpeg":{}}},
          {"id":"\(second.uuidString)","name":"Current PNG","starterID":null,"quality":41,"lossless":true,"resizeRule":{"none":{}},"keepMetadata":false,"outputFormat":{"png":{}}},
          {"id":"\(third.uuidString)","name":"   ","quality":-7,"lossless":false,"resizeRule":{"none":{}},"keepMetadata":true,"outputFormat":{"original":{}}}
        ]}
        """

        let stored = try JSONDecoder().decode(StoredPresetsV1.self, from: Data(json.utf8))
        #expect(stored.presets.map(\.id) == [first, second, third])
        #expect(stored.activePresetID == second)
        #expect(stored.presets.map(\.quality.rawValue) == [73, 41, 0])
        #expect(stored.presets.map(\.outputFormat) == [.jpeg, .png, .original])
        #expect(stored.presets[0].starterID == .web)
        #expect(stored.presets[0].resizeRule == .maxWidth(960) && stored.presets[0].keepMetadata)
        #expect(stored.presets[1].lossless && !stored.presets[1].keepMetadata)
        #expect(stored.presets[2].name == Preset.fallbackName)
    }

    @Test func unknownActivePresetIDFallsBackToTheFirstPreset() throws {
        let first = Preset(name: "First", quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)
        let second = Preset(name: "Second", quality: 60, lossless: false, resizeRule: .none, keepMetadata: false)
        let json = """
        {"version":1,"activePresetID":"00000000-0000-4000-8000-000000000001","presets":[
          {"id":"\(first.id.uuidString)","name":"First","quality":80,"lossless":false,"resizeRule":{"none":{}},"keepMetadata":false,"outputFormat":{"original":{}}},
          {"id":"\(second.id.uuidString)","name":"Second","quality":60,"lossless":false,"resizeRule":{"none":{}},"keepMetadata":false,"outputFormat":{"original":{}}}
        ]}
        """
        let restored = try JSONDecoder().decode(StoredPresetsV1.self, from: Data(json.utf8))
        #expect(restored.activePresetID == first.id)
    }

    @Test func unknownVersionAndEmptyListsAreRejected() throws {
        let unknown = Data(#"{"version":99,"activePresetID":"00000000-0000-4000-8000-000000000001","presets":[]}"#.utf8)
        #expect(throws: StoredPresetsV1.StorageError.unsupportedVersion(99)) {
            try JSONDecoder().decode(StoredPresetsV1.self, from: unknown)
        }
        let empty = try JSONEncoder().encode(StoredPresetsV1(presets: [], activePresetID: UUID()))
        #expect(throws: StoredPresetsV1.StorageError.noPresets) {
            try JSONDecoder().decode(StoredPresetsV1.self, from: empty)
        }
    }

    @Test func malformedResizeRuleAlternativesAreRejected() {
        let id = UUID()
        for rule in [#"{"none":{},"maxWidth":{"_0":10}}"#, #"{"none":10}"#] {
            let json = """
            {"version":1,"activePresetID":"\(id.uuidString)","presets":[{"id":"\(id.uuidString)","name":"A","quality":50,"lossless":false,"resizeRule":\(rule),"keepMetadata":true}]}
            """
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(StoredPresetsV1.self, from: Data(json.utf8))
            }
        }
    }

    @Test func storedValuesAreNormalizedBeforeReturningDomainPresets() throws {
        let id = UUID()
        let negativeID = UUID()
        let json = """
        {"version":1,"activePresetID":"\(id.uuidString)","presets":[
          {"id":"\(id.uuidString)","name":"  A very long preset name indeed  ","quality":250,"lossless":false,"resizeRule":{"maxHeight":{"_0":0}},"keepMetadata":false},
          {"id":"\(negativeID.uuidString)","name":" ","quality":-1,"lossless":true,"resizeRule":{"none":{}},"keepMetadata":true}
        ]}
        """
        let presets = try JSONDecoder().decode(StoredPresetsV1.self, from: Data(json.utf8)).presets
        let preset = try #require(presets.first)
        #expect(preset.isValid)
        #expect(preset.name == "A very long preset name indeed")
        #expect(preset.quality == 100)
        #expect(preset.resizeRule == .maxHeight(1))
        #expect(presets[1].name == Preset.fallbackName)
        #expect(presets[1].quality == 0)
    }

    @Test func unicodeNamesRoundTripAtAndAboveTheSeventyCharacterLimit() throws {
        let cases = [
            (name: String(repeating: "e\u{301}", count: 70), expectedCount: 70),
            (name: String(repeating: "e\u{301}", count: 71), expectedCount: 70),
            (name: String(repeating: "👍🏽", count: 70), expectedCount: 70),
            (name: String(repeating: "👍🏽", count: 71), expectedCount: 70)
        ]
        for (name, expectedCount) in cases {
            let preset = Preset(name: name, quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)
            let stored = StoredPresetsV1(presets: [preset], activePresetID: preset.id)
            let restored = try #require(JSONDecoder().decode(StoredPresetsV1.self, from: JSONEncoder().encode(stored)).presets.first)
            #expect(restored.name == String(name.prefix(expectedCount)))
            #expect(restored.name.count == expectedCount)
        }
    }
}
