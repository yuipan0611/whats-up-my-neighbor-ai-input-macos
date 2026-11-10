import Foundation
import Carbon

@main
enum SettingsStoreTests {
    static func main() {
        withStore { store, defaults in
            precondition(!store.loadDesktopPetReleased())
            precondition(store.loadAutoMeetingSummary(), "First use defaults to auto summary enabled")
            store.saveAutoMeetingSummary(false)
            precondition(!SettingsStore(defaults: defaults).loadAutoMeetingSummary())
            store.saveAutoMeetingSummary(true)
            precondition(store.loadAutoMeetingSummary())
            defaults.set("retained", forKey: "unrelatedPreference")
            store.saveDesktopPetReleased(true)
            precondition(SettingsStore(defaults: defaults).loadDesktopPetReleased())
            store.saveDesktopPetReleased(false)
            precondition(!store.loadDesktopPetReleased())
            precondition(defaults.string(forKey: "unrelatedPreference") == "retained")
            precondition(store.loadHotKey() == defaultHotKey)
            precondition(store.loadClipboardHotKey() == defaultClipboardHotKey)
            precondition(store.usesClipboardPasteGesture(), "First use enables the held-paste gesture")
            precondition(defaults.object(forKey: "clipboardHotKeyCode") == nil,
                         "Reading the first-use default must not write preferences")
            precondition(store.loadOutputMode() == .verbatim)
            precondition(store.loadLanguage() == .default)
            precondition(store.loadTextSettings() == TextSettings(
                convertChineseNumerals: false,
                silenceAutoStopSeconds: 0,
                alternateHotKey: nil,
                alternateOutputMode: .concise
            ))
            precondition(store.loadRelaySettings() == RelaySettings(
                preferredInputDeviceUID: nil,
                relayHotKey: defaultRelayHotKey
            ))
            defaults.set("lightCleanup", forKey: "textOutputMode")
            defaults.set("lightCleanup", forKey: "alternateOutputMode")
            precondition(store.loadOutputMode() == .standard)
            precondition(store.loadTextSettings().alternateOutputMode == .standard)
            defaults.set("unknown", forKey: "textOutputMode")
            defaults.set("unknown", forKey: "alternateOutputMode")
            precondition(store.loadOutputMode() == .verbatim)
            precondition(store.loadTextSettings().alternateOutputMode == .concise)
        }

        withStore { store, defaults in
            let shortcut = HotKeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
            store.saveHotKey(shortcut)
            precondition(store.loadHotKey() == shortcut)
            precondition(defaults.integer(forKey: "recordingHotKeyCode") == Int(kVK_Space))
            precondition(defaults.integer(forKey: "recordingHotKeyModifiers") == Int(cmdKey))
            defaults.removeObject(forKey: "recordingHotKeyModifiers")
            precondition(store.loadHotKey() == defaultHotKey, "Partial old preferences retain the default")
            for mode in TextOutputMode.allCases {
                store.saveOutputMode(mode)
                precondition(store.loadOutputMode() == mode)
                precondition(defaults.string(forKey: "textOutputMode") == mode.rawValue)
            }
        }

        withStore { store, defaults in
            let settings = LanguageSettings(
                primary: .japanese, additional: [.english, .traditionalChinese], automaticRetryEnabled: false
            )
            store.saveLanguage(settings)
            precondition(store.loadLanguage() == settings)
            precondition(defaults.string(forKey: "primaryLanguage") == "ja")
            defaults.removeObject(forKey: "automaticLanguageRetry")
            precondition(store.loadLanguage().automaticRetryEnabled)
            defaults.set(["en", "unknown", "zh"], forKey: "additionalLanguages")
            precondition(store.loadLanguage().additional == [.english, .traditionalChinese])
            defaults.set("unknown", forKey: "primaryLanguage")
            precondition(store.loadLanguage() == .default)
        }

        withStore { store, defaults in
            let main = HotKeyShortcut(keyCode: UInt32(kVK_F6), modifiers: UInt32(optionKey))
            store.saveHotKey(main)
            let relayBefore = store.loadRelaySettings()
            let textBefore = store.loadTextSettings()
            let clipboard = HotKeyShortcut(
                keyCode: UInt32(kVK_ANSI_C),
                modifiers: UInt32(controlKey) | UInt32(shiftKey)
            )
            store.saveClipboardHotKey(clipboard)
            precondition(SettingsStore(defaults: defaults).loadClipboardHotKey() == clipboard)
            precondition(!store.usesClipboardPasteGesture(), "Keep the user's custom shortcut without intercepting paste")
            precondition(defaults.integer(forKey: "clipboardHotKeyCode") == Int(kVK_ANSI_C))
            precondition(defaults.integer(forKey: "clipboardHotKeyModifiers") == Int(clipboard.modifiers))

            store.saveClipboardHotKey(nil)
            precondition(!SettingsStore(defaults: defaults).usesClipboardPasteGesture(),
                         "An explicitly disabled shortcut must not silently enable the gesture")
            precondition(SettingsStore(defaults: defaults).loadClipboardHotKey() == nil,
                         "Explicitly disabled clipboard shortcut must stay disabled after relaunch")
            precondition(defaults.object(forKey: "clipboardHotKeyCode") != nil)
            precondition(defaults.object(forKey: "clipboardHotKeyModifiers") != nil)
            precondition(defaults.integer(forKey: "clipboardHotKeyModifiers") == 0)

            store.saveClipboardHotKey(defaultClipboardHotKey)
            precondition(store.usesClipboardPasteGesture(), "The legacy default enables the restored gesture")
            precondition(SettingsStore(defaults: defaults).loadClipboardHotKey() == defaultClipboardHotKey,
                         "A disabled shortcut can be enabled again")
            defaults.removeObject(forKey: "clipboardHotKeyModifiers")
            precondition(store.loadClipboardHotKey() == defaultClipboardHotKey,
                         "Partial preferences fall back to the first-use shortcut")
            precondition(store.usesClipboardPasteGesture())
            precondition(store.loadHotKey() == main)
            precondition(store.loadRelaySettings() == relayBefore)
            precondition(store.loadTextSettings() == textBefore,
                         "Clipboard preferences must not change existing shortcuts or settings")
        }

        withStore { store, defaults in
            var settings = TextSettings(
                convertChineseNumerals: true, silenceAutoStopSeconds: 5,
                alternateHotKey: HotKeyShortcut(keyCode: UInt32(kVK_F6), modifiers: UInt32(optionKey)),
                alternateOutputMode: .standard
            )
            store.saveTextSettings(settings)
            precondition(SettingsStore(defaults: defaults).loadTextSettings() == settings)
            precondition(defaults.bool(forKey: "convertChineseNumerals"))
            precondition(defaults.integer(forKey: "silenceAutoStopSeconds") == 5)
            settings.alternateHotKey = nil
            store.saveTextSettings(settings)
            precondition(store.loadTextSettings() == settings)
            precondition(defaults.object(forKey: "alternateHotKeyCode") == nil)
            precondition(defaults.object(forKey: "alternateHotKeyModifiers") == nil)
        }

        withStore { store, defaults in
            var settings = RelaySettings(
                preferredInputDeviceUID: "fixture-microphone",
                relayHotKey: HotKeyShortcut(keyCode: UInt32(kVK_F7), modifiers: UInt32(optionKey))
            )
            store.saveRelaySettings(settings)
            defaults.set(true, forKey: "allowContinuityMicrophone")
            precondition(SettingsStore(defaults: defaults).loadRelaySettings() == settings)
            settings.preferredInputDeviceUID = nil
            settings.relayHotKey = nil
            store.saveRelaySettings(settings)
            precondition(SettingsStore(defaults: defaults).loadRelaySettings() == settings,
                         "Explicitly cleared relay hotkey must stay cleared after relaunch")
            precondition(defaults.object(forKey: "preferredInputDeviceUID") == nil)
            precondition(defaults.bool(forKey: "allowContinuityMicrophone"),
                         "An obsolete Continuity opt-in is ignored without deleting legacy preferences")
            precondition(defaults.object(forKey: "relayHotKeyModifiers") != nil)
            precondition(defaults.integer(forKey: "relayHotKeyModifiers") == 0)
            precondition(defaults.object(forKey: "isRelayModeEnabled") == nil)
            defaults.removeObject(forKey: "relayHotKeyCode")
            precondition(store.loadRelaySettings().relayHotKey == defaultRelayHotKey)
        }

        precondition(shortcutDisplayName(defaultHotKey) == "⌥↑")
        precondition(shortcutDisplayName(defaultRelayHotKey) == "⌃⌥↑")
        precondition(shortcutDisplayName(defaultClipboardHotKey) == "⌃⌥V")
        precondition(Set([
            HotKeyManager.primaryID, HotKeyManager.alternateID,
            HotKeyManager.relayID, HotKeyManager.clipboardID
        ]).count == 4)
        print("SettingsStoreTests passed")
    }

    /// Each case uses and removes its own preferences domain, never the user's app suite.
    static func withStore(_ body: (SettingsStore, UserDefaults) -> Void) {
        let suite = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(SettingsStore(defaults: defaults), defaults)
    }
}
