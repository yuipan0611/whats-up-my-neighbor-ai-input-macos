import AppKit

final class StatusMenuController {
    private(set) var statusItem: NSStatusItem!
    private(set) var toggleMenuItem: NSMenuItem!
    private(set) var remoteConnectionMenuItem: NSMenuItem!
    private(set) var remoteTargetMenuItem: NSMenuItem!
    private(set) var relayMenuItem: NSMenuItem!
    private(set) var clipboardPickerMenuItem: NSMenuItem!
    private(set) var desktopPetMenuItem: NSMenuItem!
    private(set) var retryMenuItem: NSMenuItem!
    private(set) var cancelMenuItem: NSMenuItem!
    private(set) var modeMenuItems: [TextOutputMode: NSMenuItem] = [:]
    private var nekoPositionItems: [NekoHUDPosition: NSMenuItem] = [:]

    func configure(target: AnyObject, toggleTitle: String, relayTitle: String, clipboardMenu: NSMenu? = nil, actions: [String: Selector]) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(.idle, description: "What's up my neighbor")

        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "What's up my neighbor", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開發版"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未編號"
        let installedVersion = NSMenuItem(title: "版本 \(version)（\(build)）", action: nil, keyEquivalent: "")
        installedVersion.isEnabled = false
        menu.addItem(installedVersion)
        menu.addItem(NSMenuItem.separator())

        toggleMenuItem = NSMenuItem(title: toggleTitle, action: actions["toggleFromMenu"], keyEquivalent: "")
        toggleMenuItem.target = target
        menu.addItem(toggleMenuItem)
        retryMenuItem = NSMenuItem(title: "重新辨識保留錄音", action: actions["retryRecordingFromMenu"], keyEquivalent: "")
        retryMenuItem.target = target
        menu.addItem(retryMenuItem)
        cancelMenuItem = NSMenuItem(title: "取消本次錄音／辨識", action: actions["cancelRecordingFromMenu"], keyEquivalent: "")
        cancelMenuItem.target = target
        menu.addItem(cancelMenuItem)

        clipboardPickerMenuItem = NSMenuItem(title: "剪貼簿歷史", action: actions["showClipboardPicker"], keyEquivalent: "")
        clipboardPickerMenuItem.target = target
        menu.addItem(clipboardPickerMenuItem)
        if let clipboardMenu {
            let settings = NSMenuItem(title: "剪貼簿設定", action: nil, keyEquivalent: "")
            settings.submenu = clipboardMenu
            menu.addItem(settings)
        }

        let modeItem = NSMenuItem(title: "文字輸出模式", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in TextOutputMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: actions["selectOutputMode"],
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = mode.rawValue
            modeMenu.addItem(item)
            modeMenuItems[mode] = item
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let vocabularyItem = NSMenuItem(title: "詞典與學習狀態…", action: actions["showVocabularyWindow"], keyEquivalent: "")
        vocabularyItem.target = target
        menu.addItem(vocabularyItem)

        desktopPetMenuItem = NSMenuItem(title: "放出小黑貓", action: actions["toggleDesktopPet"], keyEquivalent: "")
        desktopPetMenuItem.target = target
        menu.addItem(desktopPetMenuItem)

        let nekoPreview = NSMenuItem(title: "小黑貓介面預覽…", action: actions["showNekoPreview"], keyEquivalent: "")
        nekoPreview.target = target
        menu.addItem(nekoPreview)
        let vocabularyPreview = NSMenuItem(title: "預覽字典提示…", action: actions["showVocabularyPreview"], keyEquivalent: "")
        vocabularyPreview.target = target
        menu.addItem(vocabularyPreview)
        let nekoIntroduction = NSMenuItem(title: "重新查看操作引導…", action: actions["showNekoIntroduction"], keyEquivalent: "")
        nekoIntroduction.target = target
        menu.addItem(nekoIntroduction)

        let positionItem = NSMenuItem(title: "錄音浮窗位置", action: nil, keyEquivalent: "")
        let positionMenu = NSMenu()
        for position in NekoHUDPosition.allCases {
            let item = NSMenuItem(title: position.displayName, action: actions["selectNekoPosition"], keyEquivalent: "")
            item.target = target
            item.representedObject = position.rawValue
            positionMenu.addItem(item)
            nekoPositionItems[position] = item
        }
        positionItem.submenu = positionMenu
        menu.addItem(positionItem)

        let languageItem = NSMenuItem(title: "語言設定…", action: actions["showLanguageDialog"], keyEquivalent: "")
        languageItem.target = target
        menu.addItem(languageItem)

        let textSettingsItem = NSMenuItem(title: "文字與錄音設定…", action: actions["showTextSettingsDialog"], keyEquivalent: "")
        textSettingsItem.target = target
        menu.addItem(textSettingsItem)

        let shortcutItem = NSMenuItem(title: "設定快捷鍵…", action: actions["showHotKeyDialog"], keyEquivalent: "")
        shortcutItem.target = target
        menu.addItem(shortcutItem)

        let keyItem = NSMenuItem(title: "設定／更換 Groq API 金鑰…", action: actions["showAPIKeyFromMenu"], keyEquivalent: "")
        keyItem.target = target
        menu.addItem(keyItem)

        let permissionsItem = NSMenuItem(title: "開啟輔助使用權限設定…", action: actions["openAccessibilitySettings"], keyEquivalent: "")
        permissionsItem.target = target
        menu.addItem(permissionsItem)

        menu.addItem(NSMenuItem.separator())
        relayMenuItem = NSMenuItem(
            title: relayTitle,
            action: actions["toggleRelayFromMenu"],
            keyEquivalent: ""
        )
        relayMenuItem.target = target
        menu.addItem(relayMenuItem)

        remoteConnectionMenuItem = NSMenuItem(title: "iPhone 遠端：準備中…", action: nil, keyEquivalent: "")
        remoteConnectionMenuItem.isEnabled = false
        menu.addItem(remoteConnectionMenuItem)

        remoteTargetMenuItem = NSMenuItem(title: "尚未鎖定輸入框", action: nil, keyEquivalent: "")
        remoteTargetMenuItem.isEnabled = false
        menu.addItem(remoteTargetMenuItem)

        let relaySettingsItem = NSMenuItem(
            title: "iPhone 接力與麥克風設定…",
            action: actions["showRelaySettingsDialog"],
            keyEquivalent: ""
        )
        relaySettingsItem.target = target
        menu.addItem(relaySettingsItem)

        let pairingItem = NSMenuItem(title: "配對 iPhone…", action: actions["showPairingCode"], keyEquivalent: "")
        pairingItem.target = target
        menu.addItem(pairingItem)

        let forgetPhoneItem = NSMenuItem(title: "忘記已配對的 iPhone…", action: actions["forgetPairedPhone"], keyEquivalent: "")
        forgetPhoneItem.target = target
        menu.addItem(forgetPhoneItem)

        menu.addItem(NSMenuItem.separator())
        let officialWebsite = NSMenuItem(title: "官方網站", action: actions["openOfficialWebsite"], keyEquivalent: "")
        officialWebsite.target = target
        menu.addItem(officialWebsite)
        let catSettings = NSMenuItem(title: "開啟貓咪設定資料夾…", action: actions["openCatSettings"], keyEquivalent: "")
        catSettings.target = target
        menu.addItem(catSettings)
        let quit = NSMenuItem(title: "結束 What's up my neighbor", action: actions["quitApp"], keyEquivalent: "q")
        quit.target = target
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func updateClipboardShortcut(_ title: String) {
        clipboardPickerMenuItem.title = "剪貼簿歷史（\(title)）"
    }

    func updateDesktopPet(_ released: Bool) {
        desktopPetMenuItem.title = released ? "收回小黑貓" : "放出小黑貓"
    }

    func updateIcon(_ state: NekoMenuBarIcon.State, description: String) {
        statusItem.button?.image = NekoMenuBarIcon.image(for: state)
        statusItem.button?.setAccessibilityLabel(description)
        statusItem.button?.contentTintColor = nil
    }

    func updateNekoPosition(_ selected: NekoHUDPosition) {
        for (position, item) in nekoPositionItems { item.state = position == selected ? .on : .off }
    }
}
