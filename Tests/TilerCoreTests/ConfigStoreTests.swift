import Foundation
import Observation
import Testing
@testable import TilerCore

@Suite("ConfigStore")
struct ConfigStoreTests {
    /// Runs `body` with a config URL inside a fresh test directory, then deletes the directory.
    func withConfigURL(_ body: (URL) throws -> Void) throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appending(path: "Tiler/config.json"))
    }

    @Test("Settings defaults per SPEC §1")
    func settingsDefaults() {
        let s = TilerSettings.default
        #expect(s.hoverDelay == 0.15)
        #expect(s.paletteSize == 1.0)
        #expect(s.stageManagerInset == 72)
        #expect(!s.showMacOSMenuByDefault)
        #expect(!s.launchAtLogin)
        #expect(s.paletteHotkey == Hotkey(keyCode: 0x11, modifiers: Hotkey.control | Hotkey.option))
        #expect(s.paletteHotkey?.description == "⌃⌥T")
        #expect(!s.hoverTriggerEnabled) // SPEC §4.C: hover is opt-in
        #expect(TilerSettings.hoverDelayRange == 0...1)
        #expect(TilerSettings.paletteSizeRange == 0.8...2.0) // SPEC §10.1 (was 0.6…2.0)
    }

    @Test("Default path is ~/Library/Application Support/Tiler/config.json")
    func defaultPath() {
        let path = ConfigStore.defaultFileURL.path
        #expect(path.hasSuffix("/Library/Application Support/Tiler/config.json"))
        #expect(path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    @Test("Missing file → defaults, nothing written until a change")
    func missingFile() throws {
        try withConfigURL { url in
            let store = ConfigStore(fileURL: url)
            #expect(store.loadResult == .missing)
            #expect(store.config == .default)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("Round-trip: a change is saved immediately (creating the directory) and reloads identically")
    func roundTrip() throws {
        try withConfigURL { url in
            let store = ConfigStore(fileURL: url)
            store.config.settings.hoverDelay = 0.4
            store.config.settings.stageManagerInset = 80
            store.config.settings.paletteSize = 1.5
            store.config.settings.showMacOSMenuByDefault = true
            store.config.palette.add("center", at: WellPosition(row: 0, column: 0))
            store.config.palette.move(from: WellPosition(row: 2, column: 3), to: WellPosition(row: 3, column: 7))
            #expect(store.lastSaveError == nil)
            #expect(FileManager.default.fileExists(atPath: url.path))

            let reloaded = ConfigStore(fileURL: url)
            #expect(reloaded.loadResult == .loaded)
            #expect(reloaded.config == store.config)

            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            #expect(json?["version"] as? Int == 1)
            #expect(json?["settings"] is [String: Any])
            #expect(json?["palette"] is [Any])
            // Atomic write leaves no temporary files behind.
            let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            #expect(siblings == ["config.json"])
        }
    }

    @Test("Corrupt file → defaults, no crash, file untouched until the next change",
          arguments: ["", "not json at all", "{\"version\": 1, \"settings\": ", "[1, 2, 3]", "{\"version\": \"one\"}"])
    func corruptFile(contents: String) throws {
        try withConfigURL { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            let store = ConfigStore(fileURL: url)
            guard case .invalid = store.loadResult else {
                Issue.record("expected .invalid, got \(store.loadResult)")
                return
            }
            #expect(store.config == .default)
            #expect(try Data(contentsOf: url) == Data(contents.utf8))

            store.config.settings.stageManagerInset = 90
            #expect(ConfigStore(fileURL: url).config.settings.stageManagerInset == 90)
        }
    }

    @Test("Unsupported version → defaults")
    func unsupportedVersion() throws {
        try withConfigURL { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"version": 2, "settings": {"gap": 9}, "palette": []}"#.utf8).write(to: url)
            let store = ConfigStore(fileURL: url)
            guard case .invalid = store.loadResult else {
                Issue.record("expected .invalid, got \(store.loadResult)")
                return
            }
            #expect(store.config == .default)
        }
    }

    @Test("Unknown preset ids are ignored; missing keys default; out-of-range values clamp")
    func lenientDecoding() throws {
        try withConfigURL { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let json = """
            {
              "version": 1,
              "futureKey": true,
              "settings": {"hoverDelay": 7, "paletteSize": 0.1, "gap": "wide", "launchAtLogin": true},
              "palette": [
                {"id": "fill", "row": 0, "column": 0},
                {"id": "from-a-future-version", "row": 0, "column": 1},
                {"id": "arrange-4x4", "row": 5, "column": 10}
              ]
            }
            """
            try Data(json.utf8).write(to: url)
            let store = ConfigStore(fileURL: url)
            #expect(store.loadResult == .loaded)
            #expect(store.config.palette.wells == [
                WellPosition(row: 0, column: 0): "fill",
                WellPosition(row: 0, column: 1): PaletteLayout.revertID, // pre-revision-2 migration
                WellPosition(row: 5, column: 10): "arrange-4x4",
            ])
            let s = store.config.settings
            #expect(s.hoverDelay == 1)       // clamped to 0…1
            #expect(s.paletteSize == 0.8)    // clamped to 0.8…2.0 (SPEC §10.1)
            #expect(s.launchAtLogin)
            #expect(s.stageManagerInset == 72) // missing → default
        }
    }

    @Test("Old config files with the removed gap / Stage Manager toggle keys still load; the next save drops them")
    func removedSettingsKeysIgnored() throws {
        try withConfigURL { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let json = """
            {
              "version": 1,
              "settings": {"hoverDelay": 0.3, "gap": 8, "gapAppliesToScreenEdges": true,
                           "leaveRoomForStageManager": false, "stageManagerInset": 64},
              "palette": [{"id": "fill", "row": 2, "column": 3}, {"id": "left-half-sm", "row": 2, "column": 4}]
            }
            """
            try Data(json.utf8).write(to: url)
            let store = ConfigStore(fileURL: url)
            #expect(store.loadResult == .loaded)
            #expect(store.config.settings == TilerSettings(hoverDelay: 0.3, stageManagerInset: 64))
            #expect(store.config.palette.presetID(at: WellPosition(row: 2, column: 4)) == "left-half-sm")

            store.config.settings.launchAtLogin = true
            let saved = try String(contentsOf: url, encoding: .utf8)
            for removed in ["\"gap\"", "gapAppliesToScreenEdges", "leaveRoomForStageManager"] {
                #expect(!saved.contains(removed), "\(removed) still written")
            }
        }
    }

    /// Writes `json` as the config file and loads it.
    func load(_ json: String, at url: URL) throws -> ConfigStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        return ConfigStore(fileURL: url)
    }

    @Test("Config files from before the trigger settings load with ⌃⌥T and the hover trigger off")
    func preTriggerConfigFile() throws {
        try withConfigURL { url in
            // Exactly what the previous version wrote (settings without the trigger keys).
            let json = """
            {
              "palette" : [ { "column" : 3, "id" : "fill", "row" : 2 } ],
              "settings" : { "hoverDelay" : 0.25, "launchAtLogin" : false, "paletteSize" : 1.2,
                             "showMacOSMenuByDefault" : true, "stageManagerInset" : 80 },
              "version" : 1
            }
            """
            let store = try load(json, at: url)
            #expect(store.loadResult == .loaded)
            #expect(store.config.settings == TilerSettings(
                paletteHotkey: .defaultPalette, hoverTriggerEnabled: false, hoverDelay: 0.25,
                paletteSize: 1.2, stageManagerInset: 80, showMacOSMenuByDefault: true))
        }
    }

    @Test("Hotkey and hover trigger round-trip through the file")
    func triggerSettingsRoundTrip() throws {
        try withConfigURL { url in
            let store = ConfigStore(fileURL: url)
            store.config.settings.paletteHotkey = Hotkey(keyCode: 0x23, modifiers: Hotkey.command | Hotkey.shift)
            store.config.settings.hoverTriggerEnabled = true
            let reloaded = ConfigStore(fileURL: url)
            #expect(reloaded.config.settings.paletteHotkey?.description == "⇧⌘P")
            #expect(reloaded.config.settings.hoverTriggerEnabled)
            #expect(reloaded.config == store.config)

            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let settings = json?["settings"] as? [String: Any]
            let hotkey = settings?["paletteHotkey"] as? [String: Any]
            #expect(hotkey?["keyCode"] as? Int == 0x23)
            #expect(hotkey?["modifiers"] as? Int == Int(Hotkey.command | Hotkey.shift))
            #expect(settings?["hoverTriggerEnabled"] as? Bool == true)
        }
    }

    @Test("A cleared hotkey is saved as null and stays cleared after reload")
    func clearedHotkey() throws {
        try withConfigURL { url in
            let store = ConfigStore(fileURL: url)
            store.config.settings.paletteHotkey = nil
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let settings = try #require(saved?["settings"] as? [String: Any])
            #expect(settings["paletteHotkey"] is NSNull)

            let reloaded = ConfigStore(fileURL: url)
            #expect(reloaded.config.settings.paletteHotkey == nil)
            #expect(reloaded.config == store.config)
        }
    }

    @Test("Malformed trigger values fall back to their defaults without touching other settings",
          arguments: [#""⌃⌥T""#, "{}", "42", "[17, 6144]", #"{"keyCode": 999, "modifiers": 0}"#,
                      #"{"keyCode": -4, "modifiers": 0}"#, #"{"keyCode": 17, "modifiers": "ctrl"}"#])
    func malformedTriggerSettings(hotkeyJSON: String) throws {
        try withConfigURL { url in
            let json = """
            {"version": 1, "settings": {"paletteHotkey": \(hotkeyJSON), "hoverTriggerEnabled": "yes",
                                        "hoverDelay": 0.5}}
            """
            let store = try load(json, at: url)
            #expect(store.loadResult == .loaded)
            #expect(store.config.settings == TilerSettings(hoverDelay: 0.5))
        }
    }

    @Test("Unknown modifier bits in a hand-edited hotkey are dropped")
    func hotkeyModifierMask() throws {
        try withConfigURL { url in
            let json = """
            {"version": 1, "settings": {"paletteHotkey": {"keyCode": 17, "modifiers": \(0x1800 | 0x400 | 1)}}}
            """
            let store = try load(json, at: url)
            #expect(store.config.settings.paletteHotkey == .defaultPalette)
        }
    }

    @Test("A palette saved before Revert became a well gets Revert once, left of its top-left well")
    func revertMigration() throws {
        try withConfigURL { url in
            let store = try load(#"{"version": 1, "palette": [{"id": "fill", "row": 2, "column": 3}]}"#, at: url)
            #expect(store.config.palette.presetID(at: WellPosition(row: 2, column: 2)) == PaletteLayout.revertID)
            // Removing it is saved with the current revision, so it stays removed on reload.
            store.config.palette.remove(presetID: PaletteLayout.revertID)
            let saved = try String(contentsOf: url, encoding: .utf8)
            #expect(saved.contains("\"paletteRevision\" : 2"))
            #expect(ConfigStore(fileURL: url).config.palette.position(of: PaletteLayout.revertID) == nil)
        }
    }

    @Test("Revert placed by the user round-trips; the default config has it left of the default rows")
    func revertWellRoundTrip() throws {
        try withConfigURL { url in
            #expect(TilerConfig.default.palette.presetID(at: WellPosition(row: 2, column: 2)) == PaletteLayout.revertID)
            let store = ConfigStore(fileURL: url)
            store.config.palette.move(from: WellPosition(row: 2, column: 2), to: WellPosition(row: 5, column: 0))
            #expect(ConfigStore(fileURL: url).config.palette.presetID(at: WellPosition(row: 5, column: 0)) == PaletteLayout.revertID)
        }
    }

    @Test("Missing palette key → default palette; empty palette array → empty palette")
    func paletteFallbacks() throws {
        try withConfigURL { url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"version": 1}"#.utf8).write(to: url)
            #expect(ConfigStore(fileURL: url).config == .default)

            try Data(#"{"version": 1, "palette": []}"#.utf8).write(to: url)
            #expect(ConfigStore(fileURL: url).config.palette == PaletteLayout())
        }
    }

    @Test("Changes post .tilerConfigDidChange (object = store); no-op assignments do not")
    func changeNotification() throws {
        try withConfigURL { url in
            let store = ConfigStore(fileURL: url)
            let count = Box(0)
            let token = NotificationCenter.default.addObserver(
                forName: .tilerConfigDidChange, object: store, queue: nil) { _ in count.value += 1 }
            defer { NotificationCenter.default.removeObserver(token) }

            store.config.settings.paletteSize = 1.4
            #expect(count.value == 1)
            store.config.settings.paletteSize = 1.4
            #expect(count.value == 1)
            store.config.palette.remove(presetID: "fill")
            #expect(count.value == 2)
        }
    }

    @Test("Changes are observable through Observation")
    func observation() throws {
        try withConfigURL { url in
            let store = ConfigStore(fileURL: url)
            let changed = Box(false)
            withObservationTracking {
                _ = store.config
            } onChange: {
                changed.value = true
            }
            store.config.settings.paletteSize = 1.5
            #expect(changed.value)
        }
    }

    @Test("A write failure is reported, not thrown, and the in-memory change stays")
    func writeFailure() throws {
        try withConfigURL { url in
            // Make the parent path a regular file so the directory cannot be created.
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: parent)
            let store = ConfigStore(fileURL: url)
            store.config.settings.hoverDelay = 0.3
            #expect(store.lastSaveError != nil)
            #expect(store.config.settings.hoverDelay == 0.3)
        }
    }
}
