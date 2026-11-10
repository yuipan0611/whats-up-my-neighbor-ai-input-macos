import Foundation

// MARK: - 應用程式偏好設定儲存與版本相容遷移
// 集中管理 UserDefaults 鍵值、預設值以及與舊版本的欄位相容處理。
// 特別設計：接力模式（iPhone Relay）的啟用狀態刻意不予持久化保存，每次啟動 App 一律預設停用，
// 必須由使用者手動開啟，避免在使用者不知情的情況下在背景開放連線。

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
        static let autoMeetingSummary = "autoMeetingSummary"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAutoMeetingSummary() -> Bool {
        defaults.object(forKey: Keys.autoMeetingSummary) as? Bool ?? true
    }

    func saveAutoMeetingSummary(_ value: Bool) {
        defaults.set(value, forKey: Keys.autoMeetingSummary)
    }

    func loadDesktopPetReleased() -> Bool { defaults.bool(forKey: Keys.desktopPetReleased) }

    func saveDesktopPetReleased(_ value: Bool) { defaults.set(value, forKey: Keys.desktopPetReleased) }

    func loadHotKey() -> HotKeyShortcut {
        storedHotKey(codeKey: Keys.hotKeyCode, modifiersKey: Keys.hotKeyModifiers)
            ?? defaultHotKey
    }

    func saveHotKey(_ shortcut: HotKeyShortcut) {
        defaults.set(Int(shortcut.keyCode), forKey: Keys.hotKeyCode)
        defaults.set(Int(shortcut.modifiers), forKey: Keys.hotKeyModifiers)
    }

    // 載入剪貼簿搜尋全域快捷鍵：
    // 若儲存的修飾鍵為 0，表示使用者曾明確停用此快捷鍵，回傳 nil；
    // 若鍵值不存在，表示初次安裝使用，回傳預設的 ⌘⌥V。
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

    // 載入接力設定：
    // 刻意完全忽略舊版的 allowContinuityMicrophone 偏好，
    // Mac 端本機錄音絕不擅自借用 iPhone 麥克風，維持裝置選擇確定性。
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
