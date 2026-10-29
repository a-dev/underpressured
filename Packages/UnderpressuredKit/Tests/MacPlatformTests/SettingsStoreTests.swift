import Foundation
import Testing
import UnderpressuredCore
import UnderpressuredApplication
import MacPlatform

@MainActor
@Suite struct SettingsStoreTests {
    /// An isolated suite, removed again when `body` returns.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func sampleSettings() -> AppSettings {
        var list = PresetList.starter
        _ = list.duplicateActive()
        list.move(list.presets[2].id, to: 0)
        list.activate(list.presets[1].id)
        list.setOutputFormat(list.presets[1].id, to: .png)
        return AppSettings(
            presets: list,
            destination: DestinationSettings(
                kind: .exportFolder, exportFolder: URL(filePath: "/tmp/My Exports", directoryHint: .isDirectory),
                moveToTrash: true))
    }

    @Test func trashIsEnabledByDefaultAndSavedOptOutIsPreserved() {
        #expect(AppSettings.initial.destination.moveToTrash)
        withDefaults { defaults in
            defaults.set("replaceOriginals", forKey: "app.underpressured.destination.kind")
            let store = UserDefaultsSettingsStore(defaults: defaults)
            #expect(store.load()?.destination.moveToTrash == true)
            defaults.set(false, forKey: "app.underpressured.destination.moveToTrash")
            #expect(store.load()?.destination.moveToTrash == false)
        }
    }

    @Test func nothingSavedLoadsNil() {
        withDefaults { defaults in
            #expect(UserDefaultsSettingsStore(defaults: defaults).load() == nil)
        }
    }

    @Test func roundTripKeepsEveryField() {
        withDefaults { defaults in
            let settings = sampleSettings()
            UserDefaultsSettingsStore(defaults: defaults).save(settings)
            let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
            #expect(loaded == settings)
            #expect(loaded?.presets.presets.map(\.id) == settings.presets.presets.map(\.id))
            #expect(loaded?.presets.activeID == settings.presets.activeID)
            #expect(loaded?.destination.exportFolder?.path == "/tmp/My Exports")
        }
    }

    @Test func roundTripPreservesSavedPresetNamesFrom21Through70Characters() throws {
        let batches = [Array(21...40), Array(41...60), Array(61...70)]
        for lengths in batches {
            try withDefaults { defaults in
                let presets = lengths.map { length in
                    Preset(
                        name: "P" + String(repeating: "é", count: length - 1),
                        quality: .clamping(length), lossless: false, resizeRule: .none, keepMetadata: false)
                }
                let activeID = presets[presets.count / 2].id
                let settings = AppSettings(
                    presets: try PresetList.restoring(presets: presets, activeID: activeID),
                    destination: .initial)
                let store = UserDefaultsSettingsStore(defaults: defaults)

                do {
                    defaults.set(try JSONEncoder().encode(StoredPresetsV1(presets: settings.presets.presets, activePresetID: settings.presets.activeID)), forKey: "app.underpressured.presets")
                    guard let loaded = store.load() else {
                        Issue.record("Previously saved preset names did not load")
                        return
                    }
                    #expect(loaded == settings)

                    store.save(loaded)
                    let reloaded = store.load()
                    #expect(reloaded == settings)
                    #expect(reloaded?.presets.presets.map(\.name) == presets.map(\.name))
                    #expect(reloaded?.presets.presets.map(\.id) == presets.map(\.id))
                    #expect(reloaded?.presets.activeID == activeID)
                    #expect(reloaded?.presets.presets.map { $0.name.count } == lengths)
                } catch {
                    Issue.record("Preset settings roundtrip failed: \(error)")
                }
            }
        }
    }

    @Test func legacyStoreKeepsNamesIdentityOrderAndValuesAfterSave() {
        withDefaults { defaults in
            let first = UUID()
            let second = UUID()
            let json = """
            {"version":1,"activePresetID":"\(second.uuidString)","presets":[
              {"id":"\(first.uuidString)","name":"Balanced","quality":37,"lossless":true,"resizeRule":{"maxWidth":{"_0":720}},"keepMetadata":true},
              {"id":"\(second.uuidString)","name":"写真用","quality":63,"lossless":false,"resizeRule":{"none":{}},"keepMetadata":false}
            ]}
            """
            defaults.set(Data(json.utf8), forKey: "app.underpressured.presets")
            let store = UserDefaultsSettingsStore(defaults: defaults)
            guard let loaded = store.load() else { Issue.record("Legacy settings did not load"); return }
            #expect(loaded.presets.presets.map(\.id) == [first, second])
            #expect(loaded.presets.activeID == second)
            #expect(loaded.presets.presets.map(\.name) == ["Balanced", "写真用"])
            #expect(loaded.presets.presets.allSatisfy { $0.starterID == nil && $0.outputFormat == .original })
            #expect(loaded.presets.presets[0].quality == 37 && loaded.presets.presets[0].lossless)
            #expect(loaded.presets.presets[0].resizeRule == .maxWidth(720) && loaded.presets.presets[0].keepMetadata)
            store.save(loaded)
            #expect(store.load() == loaded)
        }
    }

    @Test func currentLiteralPresetFixtureKeepsDestinationAndStoredIdentity() {
        withDefaults { defaults in
            let first = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
            let second = UUID(uuidString: "40000000-0000-4000-8000-000000000002")!
            let json = """
            {"version":1,"activePresetID":"\(second.uuidString)","presets":[
              {"id":"\(first.uuidString)","name":"Saved Web","starterID":"web","quality":73,"lossless":false,"resizeRule":{"maxWidth":{"_0":960}},"keepMetadata":true,"outputFormat":{"jpeg":{}}},
              {"id":"\(second.uuidString)","name":"Saved PNG","starterID":null,"quality":41,"lossless":true,"resizeRule":{"none":{}},"keepMetadata":false,"outputFormat":{"png":{}}}
            ]}
            """
            let settings = sampleSettings()
            defaults.set(Data(json.utf8), forKey: "app.underpressured.presets")
            defaults.set("exportFolder", forKey: "app.underpressured.destination.kind")
            defaults.set("/tmp/My Exports", forKey: "app.underpressured.destination.exportFolderPath")
            defaults.set(true, forKey: "app.underpressured.destination.moveToTrash")

            let loaded = UserDefaultsSettingsStore(defaults: defaults).load()
            #expect(loaded?.presets.presets.map(\.id) == [first, second])
            #expect(loaded?.presets.activeID == second)
            #expect(loaded?.presets.presets.map(\.outputFormat) == [.jpeg, .png])
            #expect(loaded?.destination == settings.destination)
        }
    }

    @Test func clearingTheExportFolderIsRemembered() {
        withDefaults { defaults in
            let store = UserDefaultsSettingsStore(defaults: defaults)
            store.save(sampleSettings())
            var settings = sampleSettings()
            settings.destination.exportFolder = nil
            store.save(settings)
            #expect(store.load()?.destination.exportFolder == nil)
        }
    }

    @Test func missingExportFolderIsKept() {
        withDefaults { defaults in
            let store = UserDefaultsSettingsStore(defaults: defaults)
            var settings = AppSettings.initial
            settings.destination = DestinationSettings(
                kind: .exportFolder, exportFolder: URL(filePath: "/no/such/\(UUID())", directoryHint: .isDirectory))
            store.save(settings)
            #expect(store.load()?.destination == settings.destination)
        }
    }

    private func withFolder(_ body: (URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("up-SettingsStoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try body(parent)
    }

    private func exportSettings(_ folder: URL) -> AppSettings {
        var settings = AppSettings.initial
        settings.destination = DestinationSettings(kind: .exportFolder, exportFolder: folder)
        return settings
    }

    @Test func bookmarkFollowsAMovedExportFolderAndThePathKeyStaysForOlderBuilds() throws {
        try withDefaults { defaults in
            try withFolder { parent in
                let original = parent.appendingPathComponent("Exports", isDirectory: true)
                let moved = parent.appendingPathComponent("Renamed", isDirectory: true)
                try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
                UserDefaultsSettingsStore(defaults: defaults).save(exportSettings(original))
                #expect(defaults.data(forKey: "app.underpressured.destination.exportFolderBookmark") != nil)
                #expect(defaults.string(forKey: "app.underpressured.destination.exportFolderPath") == original.path(percentEncoded: false))

                try FileManager.default.moveItem(at: original, to: moved)
                let store = UserDefaultsSettingsStore(defaults: defaults)
                let loaded = try #require(store.load()?.destination.exportFolder)
                #expect(loaded.resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path)

                store.save(exportSettings(loaded))
                #expect(defaults.string(forKey: "app.underpressured.destination.exportFolderPath") == loaded.path(percentEncoded: false))
            }
        }
    }

    @Test func unresolvableBookmarkFallsBackToTheSavedPath() throws {
        try withDefaults { defaults in
            try withFolder { parent in
                let folder = parent.appendingPathComponent("Gone", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                UserDefaultsSettingsStore(defaults: defaults).save(exportSettings(folder))
                try FileManager.default.removeItem(at: folder)

                let loaded = UserDefaultsSettingsStore(defaults: defaults).load()?.destination.exportFolder
                #expect(loaded?.path(percentEncoded: false) == folder.path(percentEncoded: false))
            }
        }
    }

    @Test func aFolderThatCannotBeBookmarkedReplacesTheEarlierBookmark() throws {
        try withDefaults { defaults in
            try withFolder { parent in
                let first = parent.appendingPathComponent("First", isDirectory: true)
                try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
                let store = UserDefaultsSettingsStore(defaults: defaults)
                store.save(exportSettings(first))
                let missing = URL(filePath: "/no/such/\(UUID())", directoryHint: .isDirectory)
                store.save(exportSettings(missing))

                #expect(defaults.data(forKey: "app.underpressured.destination.exportFolderBookmark") == nil)
                #expect(UserDefaultsSettingsStore(defaults: defaults).load()?.destination.exportFolder == missing)
            }
        }
    }

    @Test func corruptPresetsFallBackToStartersAndKeepTheRest() {
        withDefaults { defaults in
            let store = UserDefaultsSettingsStore(defaults: defaults)
            let settings = sampleSettings()
            store.save(settings)
            defaults.set(Data("not json".utf8), forKey: "app.underpressured.presets")

            let loaded = store.load()
            #expect(loaded?.presets.presets.map(\.name) == Preset.starters.map(\.name))
            #expect(loaded?.presets.activeID == loaded?.presets.presets.first?.id)
            #expect(loaded?.destination == settings.destination)
        }
    }

    @Test func unknownPresetVersionFallsBackToStarters() throws {
        withDefaults { defaults in
            let store = UserDefaultsSettingsStore(defaults: defaults)
            let settings = sampleSettings()
            store.save(settings)
            defaults.set(Data(#"{"version":99,"activePresetID":"00000000-0000-4000-8000-000000000001","presets":[]}"#.utf8), forKey: "app.underpressured.presets")

            let loaded = store.load()
            #expect(loaded?.presets.presets.map(\.name) == Preset.starters.map(\.name))
            #expect(loaded?.destination == settings.destination)
        }
    }

    @Test func duplicateIDsAndTwentyOnePresetsFallBackAndKeepDestination() throws {
        try withDefaults { defaults in
            let destination = sampleSettings().destination
            let id = UUID(uuidString: "50000000-0000-4000-8000-000000000001")!
            let duplicateJSON = """
            {"version":1,"activePresetID":"\(id.uuidString)","presets":[
              {"id":"\(id.uuidString)","name":"One","quality":80,"lossless":false,"resizeRule":{"none":{}},"keepMetadata":false,"outputFormat":{"original":{}}},
              {"id":"\(id.uuidString)","name":"Two","quality":60,"lossless":false,"resizeRule":{"none":{}},"keepMetadata":false,"outputFormat":{"original":{}}}
            ]}
            """
            let presets = (0..<21).map { index in
                Preset(name: "Preset \(index)", quality: 80, lossless: false, resizeRule: .none, keepMetadata: false)
            }
            let oversized = try JSONEncoder().encode(StoredPresetsV1(presets: presets, activePresetID: presets[0].id))
            let store = UserDefaultsSettingsStore(defaults: defaults)

            for payload in [Data(duplicateJSON.utf8), oversized] {
                store.save(sampleSettings())
                defaults.set(payload, forKey: "app.underpressured.presets")
                let loaded = store.load()
                #expect(loaded?.presets.presets.map(\.name) == Preset.starters.map(\.name))
                #expect(loaded?.presets.presets.map(\.settings) == Preset.starters.map(\.settings))
                #expect(loaded?.presets.activeID == loaded?.presets.presets.first?.id)
                #expect(loaded?.destination == destination)
            }
        }
    }

    @Test func emptyMalformedAndUnknownVersionPayloadsFallBackAndKeepDestination() throws {
        try withDefaults { defaults in
            let settings = sampleSettings()
            let store = UserDefaultsSettingsStore(defaults: defaults)
            let empty = try JSONEncoder().encode(StoredPresetsV1(presets: [], activePresetID: UUID()))
            let unknownVersion = Data(#"{"version":99,"activePresetID":"00000000-0000-4000-8000-000000000001","presets":[]}"#.utf8)
            let payloads = [empty, Data("not json".utf8), unknownVersion]

            for payload in payloads {
                store.save(settings)
                defaults.set(payload, forKey: "app.underpressured.presets")
                let loaded = store.load()
                #expect(loaded?.presets.presets.map(\.name) == Preset.starters.map(\.name))
                #expect(loaded?.presets.presets.map(\.settings) == Preset.starters.map(\.settings))
                #expect(loaded?.presets.activeID == loaded?.presets.presets.first?.id)
                #expect(loaded?.destination == settings.destination)
            }
        }
    }

    @Test func unknownDestinationFallsBack() {
        withDefaults { defaults in
            let store = UserDefaultsSettingsStore(defaults: defaults)
            let settings = sampleSettings()
            store.save(settings)
            defaults.set("somewhere", forKey: "app.underpressured.destination.kind")

            let loaded = store.load()
            #expect(loaded?.destination.kind == .replaceOriginals)
            #expect(loaded?.destination.exportFolder == settings.destination.exportFolder)
            #expect(loaded?.presets == settings.presets)
        }
    }


}
