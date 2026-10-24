import Foundation

struct TextSettings: Equatable {
    var convertChineseNumerals: Bool
    var silenceAutoStopSeconds: Int
    var alternateHotKey: HotKeyShortcut?
    var alternateOutputMode: TextOutputMode
}

struct RelaySettings: Equatable {
    var preferredInputDeviceUID: String?
    var relayHotKey: HotKeyShortcut?
}

/// Keeps the existing preference keys and migration/default behavior in one place.
/// Relay activation is intentionally absent: every launch starts with relay disabled.
final class SettingsStore {
    private enum Keys {
        static let hotKeyCode = "recordingHotKeyCode"
        static let hotKeyModifiers = "recordingHotKeyModifiers"
        static let textOutputMode = "textOutputMode"
        static let alternateHotKeyCode = "alternateHotKeyCode"
        static let alternateHotKeyModifiers = "alternateHotKeyModifiers"
        static let alternateOutputMode = "alternateOutputMode"
        static let primaryLanguage = "primaryLanguage"
        static let additionalLanguages = "additionalLanguages"
        static let automaticLanguageRetry = "automaticLanguageRetry"
        static let convertChineseNumerals = "convertChineseNumerals"
        static let silenceAutoStopSeconds = "silenceAutoStopSeconds"
        static let relayHotKeyCode = "relayHotKeyCode"
        static let relayHotKeyModifiers = "relayHotKeyModifiers"
        static let clipboardHotKeyCode = "clipboardHotKeyCode"
        static let clipboardHotKeyModifiers = "clipboardHotKeyModifiers"
        static let preferredInputDeviceUID = "preferredInputDeviceUID"
        static let desktopPetReleased = "desktopPetReleased"
        static let selectedCatPackID = "selectedCatPackID"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadDesktopPetReleased() -> Bool { defaults.bool(forKey: Keys.desktopPetReleased) }

    func saveDesktopPetReleased(_ value: Bool) { defaults.set(value, forKey: Keys.desktopPetReleased) }

    func loadSelectedCatPackID() -> String? { defaults.string(forKey: Keys.selectedCatPackID) }

    func saveSelectedCatPackID(_ value: String?) { defaults.set(value, forKey: Keys.selectedCatPackID) }

    func loadHotKey() -> HotKeyShortcut {
        storedHotKey(codeKey: Keys.hotKeyCode, modifiersKey: Keys.hotKeyModifiers)
            ?? defaultHotKey
    }

    func saveHotKey(_ shortcut: HotKeyShortcut) {
        defaults.set(Int(shortcut.keyCode), forKey: Keys.hotKeyCode)
        defaults.set(Int(shortcut.modifiers), forKey: Keys.hotKeyModifiers)
    }

    func loadClipboardHotKey() -> HotKeyShortcut? {
        guard let stored = storedHotKey(
            codeKey: Keys.clipboardHotKeyCode,
            modifiersKey: Keys.clipboardHotKeyModifiers
        ) else { return defaultClipboardHotKey }
        // Keep explicit disabling distinct from first use, including after relaunch.
        return stored.modifiers == 0 ? nil : stored
    }

    func saveClipboardHotKey(_ shortcut: HotKeyShortcut?) {
        defaults.set(Int(shortcut?.keyCode ?? 0), forKey: Keys.clipboardHotKeyCode)
        defaults.set(Int(shortcut?.modifiers ?? 0), forKey: Keys.clipboardHotKeyModifiers)
    }

    /// Restore the held-paste gesture for the default without rewriting existing
    /// preferences. Explicitly disabled and custom shortcuts keep their meaning.
    func usesClipboardPasteGesture() -> Bool {
        guard let stored = storedHotKey(codeKey: Keys.clipboardHotKeyCode,
                                        modifiersKey: Keys.clipboardHotKeyModifiers) else { return true }
        return stored == defaultClipboardHotKey
    }

    func loadOutputMode() -> TextOutputMode {
        TextOutputMode.fromStoredValue(defaults.string(forKey: Keys.textOutputMode))
            ?? .verbatim
    }

    func saveOutputMode(_ mode: TextOutputMode) {
        defaults.set(mode.rawValue, forKey: Keys.textOutputMode)
    }

    func loadLanguage() -> LanguageSettings {
        guard let raw = defaults.string(forKey: Keys.primaryLanguage),
              let primary = LanguageOption(rawValue: raw) else {
            return .default
        }
        let additional = (defaults.stringArray(forKey: Keys.additionalLanguages) ?? [])
            .compactMap(LanguageOption.init(rawValue:))
        let retry = defaults.object(forKey: Keys.automaticLanguageRetry) as? Bool ?? true
        return LanguageSettings(
            primary: primary,
            additional: additional,
            automaticRetryEnabled: retry
        )
    }

    func saveLanguage(_ settings: LanguageSettings) {
        defaults.set(settings.primary.rawValue, forKey: Keys.primaryLanguage)
        defaults.set(settings.additional.map(\.rawValue), forKey: Keys.additionalLanguages)
        defaults.set(settings.automaticRetryEnabled, forKey: Keys.automaticLanguageRetry)
    }

    func loadTextSettings() -> TextSettings {
        TextSettings(
            convertChineseNumerals: defaults.bool(forKey: Keys.convertChineseNumerals),
            silenceAutoStopSeconds: defaults.integer(forKey: Keys.silenceAutoStopSeconds),
            alternateHotKey: storedHotKey(
                codeKey: Keys.alternateHotKeyCode,
                modifiersKey: Keys.alternateHotKeyModifiers
            ),
            alternateOutputMode: TextOutputMode.fromStoredValue(
                defaults.string(forKey: Keys.alternateOutputMode)
            ) ?? .concise
        )
    }

    func saveTextSettings(_ settings: TextSettings) {
        defaults.set(settings.convertChineseNumerals, forKey: Keys.convertChineseNumerals)
        defaults.set(settings.silenceAutoStopSeconds, forKey: Keys.silenceAutoStopSeconds)
        defaults.set(settings.alternateOutputMode.rawValue, forKey: Keys.alternateOutputMode)
        if let shortcut = settings.alternateHotKey {
            defaults.set(Int(shortcut.keyCode), forKey: Keys.alternateHotKeyCode)
            defaults.set(Int(shortcut.modifiers), forKey: Keys.alternateHotKeyModifiers)
        } else {
            defaults.removeObject(forKey: Keys.alternateHotKeyCode)
            defaults.removeObject(forKey: Keys.alternateHotKeyModifiers)
        }
    }

    func loadRelaySettings() -> RelaySettings {
        // Legacy allowContinuityMicrophone is deliberately ignored. Desktop
        // recording never uses phone hardware, regardless of old preferences.
        let stored = storedHotKey(
            codeKey: Keys.relayHotKeyCode,
            modifiersKey: Keys.relayHotKeyModifiers
        )
        // Absent keys mean first launch; zero modifiers mean explicitly cleared.
        let shortcut: HotKeyShortcut?
        if let stored {
            shortcut = stored.modifiers == 0 ? nil : stored
        } else {
            shortcut = defaultRelayHotKey
        }
        return RelaySettings(
            preferredInputDeviceUID: defaults.string(forKey: Keys.preferredInputDeviceUID),
            relayHotKey: shortcut
        )
    }

    func saveRelaySettings(_ settings: RelaySettings) {
        if let uid = settings.preferredInputDeviceUID {
            defaults.set(uid, forKey: Keys.preferredInputDeviceUID)
        } else {
            defaults.removeObject(forKey: Keys.preferredInputDeviceUID)
        }
        defaults.set(Int(settings.relayHotKey?.keyCode ?? 0), forKey: Keys.relayHotKeyCode)
        defaults.set(Int(settings.relayHotKey?.modifiers ?? 0), forKey: Keys.relayHotKeyModifiers)
    }

    private func storedHotKey(codeKey: String, modifiersKey: String) -> HotKeyShortcut? {
        guard defaults.object(forKey: codeKey) != nil,
              defaults.object(forKey: modifiersKey) != nil else { return nil }
        return HotKeyShortcut(
            keyCode: UInt32(defaults.integer(forKey: codeKey)),
            modifiers: UInt32(defaults.integer(forKey: modifiersKey))
        )
    }
}
