import AppKit

// MARK: - macOS 狀態列選單控制器（Status Menu Controller）
// 負責在系統選單列（Menu Bar Extra）建立與維護常駐圖示及完整功能選單。
// 功能涵蓋：
// 1. 錄音狀態切換、重新辨識與取消控制。
// 2. 剪貼簿歷史與子選單綁定。
// 3. 輸出文字模式選擇、詞彙學習字典預覽、桌寵黑貓放出/收回開關。
// 4. iPhone 遠端接力狀態顯示與配對控制。
// 5. 即時更新選單項目文字（如快捷鍵按鍵名稱、接力連線狀態、貓咪選單位置等）。

final class StatusMenuController: NSObject, NSMenuDelegate {
    var onMenuWillOpen: (() -> Void)?
    private(set) var statusItem: NSStatusItem!
    private var vpsDesktopMenuItem: NSMenuItem?
    private(set) var toggleMenuItem: NSMenuItem!
    private(set) var remoteConnectionMenuItem: NSMenuItem!
    private(set) var remoteTargetMenuItem: NSMenuItem!
    private(set) var relayMenuItem: NSMenuItem!
    private(set) var clipboardPickerMenuItem: NSMenuItem!
    private(set) var desktopPetMenuItem: NSMenuItem!
    private(set) var retryMenuItem: NSMenuItem!
    private(set) var cancelMenuItem: NSMenuItem!
    private(set) var meetingToggleMenuItem: NSMenuItem!
    private(set) var summarizeLatestMeetingMenuItem: NSMenuItem!
    private(set) var autoSummaryMenuItem: NSMenuItem!
    private(set) var meetingDiarizationToggleMenuItem: NSMenuItem!
    private(set) var meetingDiarizationStatusMenuItem: NSMenuItem!
    private(set) var meetingDeleteAudioMenuItem: NSMenuItem!
    private(set) var meetingRetryDiarizationMenuItem: NSMenuItem!
    private(set) var modeMenuItems: [TextOutputMode: NSMenuItem] = [:]
    private var nekoPositionItems: [NekoHUDPosition: NSMenuItem] = [:]
    private var catCoatItems: [String: NSMenuItem] = [:]

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
        if let revision = Bundle.main.object(forInfoDictionaryKey: "NekoDevelopmentRevision") as? String {
            let qaBuild = NSMenuItem(title: "QA 測試版 · \(revision.prefix(7))", action: nil, keyEquivalent: "")
            qaBuild.isEnabled = false
            menu.addItem(qaBuild)
        }
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

        menu.addItem(NSMenuItem.separator())
        meetingToggleMenuItem = NSMenuItem(title: "開始會議記錄", action: actions["toggleMeetingFromMenu"], keyEquivalent: "")
        meetingToggleMenuItem.target = target
        menu.addItem(meetingToggleMenuItem)
        let meetingFolder = NSMenuItem(title: "開啟會議資料夾", action: actions["openMeetingFolder"], keyEquivalent: "")
        meetingFolder.target = target
        menu.addItem(meetingFolder)
        let meetingCopy = NSMenuItem(title: "複製最近一次逐字稿", action: actions["copyLatestMeetingTranscript"], keyEquivalent: "")
        meetingCopy.target = target
        menu.addItem(meetingCopy)
        summarizeLatestMeetingMenuItem = NSMenuItem(title: "為最近一次會議產生摘要", action: actions["summarizeLatestMeeting"], keyEquivalent: "")
        summarizeLatestMeetingMenuItem.target = target
        menu.addItem(summarizeLatestMeetingMenuItem)
        autoSummaryMenuItem = NSMenuItem(title: "自動產生會議摘要", action: actions["toggleAutoSummary"], keyEquivalent: "")
        autoSummaryMenuItem.target = target
        menu.addItem(autoSummaryMenuItem)
        meetingDiarizationToggleMenuItem = NSMenuItem(title: "會議說話者辨識（實驗）", action: actions["toggleMeetingDiarization"], keyEquivalent: "")
        meetingDiarizationToggleMenuItem.target = target
        menu.addItem(meetingDiarizationToggleMenuItem)
        // 以下兩項平常隱藏：只有說話者辨識進行中、或辨識沒成功而音檔還在時才出現。
        meetingDiarizationStatusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        meetingDiarizationStatusMenuItem.isEnabled = false
        meetingDiarizationStatusMenuItem.isHidden = true
        menu.addItem(meetingDiarizationStatusMenuItem)
        meetingDeleteAudioMenuItem = NSMenuItem(title: "刪除這場會議的音檔", action: actions["deleteMeetingAudio"], keyEquivalent: "")
        meetingDeleteAudioMenuItem.target = target
        meetingDeleteAudioMenuItem.isHidden = true
        menu.addItem(meetingDeleteAudioMenuItem)
        meetingRetryDiarizationMenuItem = NSMenuItem(title: "重新辨識最近一次會議的說話者", action: actions["retryMeetingDiarization"], keyEquivalent: "")
        meetingRetryDiarizationMenuItem.target = target
        meetingRetryDiarizationMenuItem.isHidden = true
        menu.addItem(meetingRetryDiarizationMenuItem)
        menu.addItem(NSMenuItem.separator())

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

        if let action = actions["selectCatCoat"] {
            let (catCoatItem, items) = CatCoatMenu.make(target: target, action: action)
            catCoatItems = items
            menu.addItem(catCoatItem)
        }

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

        if let action = actions["showVPSDesktop"] {
            menu.addItem(NSMenuItem.separator())
            let vpsItem = NSMenuItem(title: "VPS 遠端桌面…", action: action, keyEquivalent: "")
            vpsItem.target = target
            menu.addItem(vpsItem)
            vpsDesktopMenuItem = vpsItem
        }

        menu.addItem(NSMenuItem.separator())
        let catSettings = NSMenuItem(title: "開啟貓咪設定資料夾…", action: actions["openCatSettings"], keyEquivalent: "")
        catSettings.target = target
        menu.addItem(catSettings)
        let quit = NSMenuItem(title: "結束 What's up my neighbor", action: actions["quitApp"], keyEquivalent: "q")
        quit.target = target
        menu.addItem(quit)
        menu.delegate = self
        statusItem.menu = menu
    }

    func updateMeetingDiarization(enabled: Bool, supported: Bool) {
        meetingDiarizationToggleMenuItem?.state = enabled ? .on : .off
        // 不支援的機器（Intel）：功能停用，標題說明原因。
        meetingDiarizationToggleMenuItem?.isEnabled = supported
        meetingDiarizationToggleMenuItem?.title = supported
            ? "會議說話者辨識（實驗）" : "會議說話者辨識（實驗）— \(MeetingDiarizerSupport.unsupportedMessage)"
    }

    /// `statusTitle` 為 nil 時隱藏狀態列；`canDeleteAudio` 控制「刪除這場會議的音檔」是否出現。
    func updateMeetingDiarizationStatus(statusTitle: String?, canDeleteAudio: Bool, canRetry: Bool = false) {
        meetingRetryDiarizationMenuItem?.isHidden = !canRetry
        meetingDiarizationStatusMenuItem?.title = statusTitle ?? ""
        meetingDiarizationStatusMenuItem?.isHidden = statusTitle == nil
        meetingDeleteAudioMenuItem?.isHidden = !canDeleteAudio
    }

    func updateMeeting(title: String, enabled: Bool) {
        meetingToggleMenuItem?.title = title
        meetingToggleMenuItem?.isEnabled = enabled
    }

    func updateAutoSummary(enabled: Bool) {
        autoSummaryMenuItem?.state = enabled ? .on : .off
    }

    func updateSummarizeLatestMeeting(title: String, enabled: Bool) {
        summarizeLatestMeetingMenuItem?.title = title
        summarizeLatestMeetingMenuItem?.isEnabled = enabled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        onMenuWillOpen?()
    }

    /// One look for everyone: clickable when this Mac has the VPS set up, gray otherwise.
    func updateVPSDesktop(available: Bool) {
        vpsDesktopMenuItem?.isEnabled = available
        vpsDesktopMenuItem?.toolTip = available ? nil : "需要先設定 VPS 連線"
    }

    func updateClipboardShortcut(_ title: String) {
        clipboardPickerMenuItem.title = "剪貼簿歷史（\(title)）"
    }

    func updateDesktopPet(_ released: Bool) {
        desktopPetMenuItem.title = released ? "收回小黑貓" : "放出小黑貓"
    }

    func updateCatCoat(_ selected: String) {
        for (id, item) in catCoatItems { item.state = id == selected ? .on : .off }
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
