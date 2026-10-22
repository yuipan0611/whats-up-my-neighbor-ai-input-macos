import AppKit
import AVFoundation
import ApplicationServices
import Carbon
import Security

final class VoiceTypeController: NSObject, NSApplicationDelegate {
    private let statusMenu = StatusMenuController()
    private var statusItem: NSStatusItem { statusMenu.statusItem }
    private var toggleMenuItem: NSMenuItem { statusMenu.toggleMenuItem }
    private var remoteConnectionMenuItem: NSMenuItem { statusMenu.remoteConnectionMenuItem }
    private var remoteTargetMenuItem: NSMenuItem { statusMenu.remoteTargetMenuItem }
    private var relayMenuItem: NSMenuItem { statusMenu.relayMenuItem }
    private var modeMenuItems: [TextOutputMode: NSMenuItem] { statusMenu.modeMenuItems }
    private let hotKeys = HotKeyManager()
    private let settings = SettingsStore()
    private let credentials = KeychainStore()
    private let recordingStore = TemporaryRecordingStore()
    private let micRecorder = PinnedMicrophoneRecorder()
    private let catConfiguration = CatConfiguration.load()
    private lazy var recordingCatImage: NSImage? = {
        guard catConfiguration.image == nil, let original = NekoAppearance.catImage else { return NekoAppearance.catImage }
        return CatAppearanceArtwork(catConfiguration.appearance).image(original, layout: .hud)
    }()
    private lazy var nekoHUD = NekoRecordingHUD(image: catConfiguration.imageData.flatMap(NSImage.init(data:)) ?? recordingCatImage)
    private lazy var catGreeting = CatGreeting(configuration: catConfiguration)
    private lazy var catOverlay = CatOverlay(configuration: catConfiguration)
    private lazy var desktopPet: DesktopPetController = {
        let pet = DesktopPetController(appearance: catConfiguration.appearance)
        pet.isBusy = { [weak self] in
            guard let self else { return true }
            return self.dictation.state != .idle || self.clipboardPicker.isVisible ||
                self.catOverlay.isVisible || self.nekoHUD.isVisible || NSApp.modalWindow != nil
        }
        pet.onReleasedChange = { [weak self] released in
            self?.settings.saveDesktopPetReleased(released)
            self?.statusMenu.updateDesktopPet(released)
        }
        return pet
    }()
    private lazy var appUpdater = AppUpdateController { [weak self] in
        guard let self else { return true }
        return self.dictation.state != .idle || self.micRecorder.isBusy || NSApp.modalWindow != nil
    }
    private let vocabularyStore = MacVocabularyStore()
    private lazy var vocabularyLearning = VocabularyLearningStore(vocabulary: vocabularyStore)
    private lazy var vocabularyToast = VocabularyLearningToastController(store: vocabularyLearning)
    private let correctionMonitor = PasteCorrectionMonitor()
    private var vocabularyWindow: VocabularyWindowController?
    private let clipboardHistoryStore = ClipboardHistoryStore()
    private lazy var clipboardHistory = ClipboardHistoryMonitor(store: clipboardHistoryStore)
    private let clipboardHistoryMenu = ClipboardHistoryMenuController()
    private let focusTargets = FocusTargetService()
    private lazy var clipboardPicker = ClipboardPickerController(focusTargets: focusTargets, textInsertion: textInsertion)
    private lazy var textInsertion: TextInsertionService = {
        var environment = TextInsertionService.Environment.system
        environment.copyText = { [weak self] text in
            self?.clipboardHistory.copyText(text) ?? false
        }
        return TextInsertionService(focusTargets: focusTargets, environment: environment)
    }()
    private var dictationTarget: FocusTarget?
    private var targetCaptureFailure: FocusTargetError?
    private lazy var dictation = DictationCoordinator(
        recorder: micRecorder,
        transcriber: GroqDictationTranscriber(
            readAPIKey: { [weak self] in self?.credentials.readAPIKey() },
            makePrompt: { [weak self] language, reinforce in
                let primary = language.primary
                let allowed = language.allowedLanguages.map(\.displayName).joined(separator: "、")
                let hint = reinforce ? "這段錄音的語言是\(primary.displayName)，可能混合少量\(allowed)。請只輸出這些語言。" : ""
                return self?.vocabularyLearning.prompt(base: hint + primary.transcriptionPrompt) ?? primary.transcriptionPrompt
            }),
        storage: recordingStore
    )
    private var currentHotKey = defaultHotKey
    private var clipboardHotKey: HotKeyShortcut? = defaultClipboardHotKey
    private var clipboardHotKeyRegistrationFailed = false
    private var clipboardShortcutTitle: String {
        guard let clipboardHotKey else { return "未設定" }
        let title = shortcutDisplayName(clipboardHotKey)
        return clipboardHotKeyRegistrationFailed ? "\(title)，無法使用" : title
    }
    private var alternateHotKey: HotKeyShortcut?
    private var relayHotKey: HotKeyShortcut? = defaultRelayHotKey
    private var alternateOutputMode: TextOutputMode = .concise
    private var languageSettings = LanguageSettings.default
    private var convertChineseNumerals = false
    private var silenceAutoStopSeconds = 0
    private var preferredInputDeviceUID: String?
    private var textOutputMode: TextOutputMode = .verbatim
    private var isRelayModeEnabled = false
    private var meteringTimer: Timer?
    private let remoteBridge = MacRemoteBridge()
    private lazy var remoteTargetController = RemoteTargetController(
        focusTargets: focusTargets, textInsertion: textInsertion
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UpdateDiagnostics.shared.record(.launch, version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        UpdateDiagnostics.shared.record(.microphoneAuthorized, succeeded: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        UpdateDiagnostics.shared.record(.accessibilityAllowed, succeeded: AXIsProcessTrusted())
        if PasteDiagnostics.shared.isEnabled {
            var event = PasteDiagnostics.Event(tag: .startup)
            event.trusted = AXIsProcessTrusted()
            event.postEventPermission = CGPreflightPostEventAccess()
            event.secureEventInputEnabled = IsSecureEventInputEnabled()
            PasteDiagnostics.shared.record(event)
        }
        // Use the packaged icon for alerts immediately, even if Launch Services cached an older release.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: iconURL)
        }
        recordingStore.cleanupStaleRecordings()
        currentHotKey = settings.loadHotKey()
        clipboardHotKey = settings.loadClipboardHotKey()
        textOutputMode = settings.loadOutputMode()
        languageSettings = settings.loadLanguage()
        loadTextSettings()
        loadRelaySettings()
        configureClipboardHistory()
        configureStatusItem()
        configureDictation()
        correctionMonitor.onCandidate = { [weak self] candidate in
            guard let self else { return }
            if self.dictation.state == .idle { self.nekoHUD.hide() }
            self.vocabularyToast.show(candidate, targetFrame: self.correctionMonitor.presentationFrame(), isStillValid: { [weak self] in
                self?.correctionMonitor.isCurrentCorrectionValid() ?? false
            }, onResolved: { [weak self] in
                self?.correctionMonitor.finishCurrentCorrection()
            })
        }
        correctionMonitor.onEditingResumed = { [weak self] in self?.vocabularyToast.cancelPendingCorrection() }
        correctionMonitor.onStopped = { [weak self] in self?.vocabularyToast.cancelPendingCorrection() }
        correctionMonitor.onStatus = { [weak self] in self?.vocabularyLearning.report($0) }
        configureRemoteInput()
        registerHotKey()
        requestPermissions()
        appUpdater.start()

        // Show the guide once per user, not once per build; never open the microphone.
        nekoHUD.showIntroductionIfNeeded(shortcut: shortcutDisplayName(currentHotKey))
        desktopPet.setReleased(settings.loadDesktopPetReleased())

        let hasAPIKey = credentials.readAPIKey() != nil
        UpdateDiagnostics.shared.record(.apiKeyAccess, succeeded: hasAPIKey)
        if !hasAPIKey {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.showAPIKeyDialog(firstRun: true)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        meteringTimer?.invalidate()
        clipboardHistory.stop()
        clipboardPicker.dismiss()
        clipboardHistoryStore.flush()
        nekoHUD.hide()
        catOverlay.dispose()
        desktopPet.dispose()
        correctionMonitor.stop()
        dictation.shutdown()
        hotKeys.unregisterAll()
        remoteBridge.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if dictation.state == .idle { showNekoPreview() }
        else { nekoHUD.update(state: dictation.state) }
        return false
    }

    private func configureStatusItem() {
        statusMenu.configure(target: self, toggleTitle: toggleMenuTitle(), relayTitle: relayMenuTitle(), clipboardMenu: clipboardHistoryMenu.menu, actions: [
            "openCatSettings": #selector(openCatSettings),
            "openOfficialWebsite": #selector(openOfficialWebsite),
            "showVocabularyWindow": #selector(showVocabularyWindow),
            "showNekoPreview": #selector(showNekoPreview),
            "toggleDesktopPet": #selector(toggleDesktopPet),
            "showVocabularyPreview": #selector(showVocabularyPreview),
            "showNekoIntroduction": #selector(showNekoIntroduction),
            "selectNekoPosition": #selector(selectNekoPosition(_:)),
            "toggleFromMenu": #selector(toggleFromMenu),
            "retryRecordingFromMenu": #selector(retryRecordingFromMenu),
            "cancelRecordingFromMenu": #selector(cancelRecordingFromMenu),
            "selectOutputMode": #selector(selectOutputMode(_:)),
            "showLanguageDialog": #selector(showLanguageDialog),
            "showTextSettingsDialog": #selector(showTextSettingsDialog),
            "showHotKeyDialog": #selector(showHotKeyDialog),
            "showClipboardPicker": #selector(showClipboardPicker),
            "showAPIKeyFromMenu": #selector(showAPIKeyFromMenu),
            "openAccessibilitySettings": #selector(openAccessibilitySettings),
            "toggleRelayFromMenu": #selector(toggleRelayFromMenu),
            "showRelaySettingsDialog": #selector(showRelaySettingsDialog),
            "showPairingCode": #selector(showPairingCode),
            "forgetPairedPhone": #selector(forgetPairedPhone),
            "quitApp": #selector(quitApp),
        ])
        if let menu = statusItem.menu { appUpdater.addMenuItems(to: menu) }
        statusMenu.updateClipboardShortcut(clipboardShortcutTitle)
        updateTextOutputModeMenu()
        statusMenu.updateNekoPosition(nekoHUD.position)
        updateRelayMenu()
        renderDictationState(.idle)
    }

    private func configureClipboardHistory() {
        clipboardPicker.isCurrentItem = { [weak self] item in
            self?.clipboardHistoryStore.item(id: item.id) == item
        }
        clipboardPicker.onInsertResult = { [weak self] result in
            switch result {
            case .pasteEventPosted: break
            case .copiedOnly:
                self?.showError("文字已複製，但輸入位置已改變或無法驗證。請回到輸入框按 ⌘V。")
            case .copyFailed:
                self?.showError("無法複製這筆文字，請再試一次。")
            }
        }
        clipboardHistoryMenu.onWillOpen = { [weak self] in
            guard let self else { return }
            self.clipboardHistory.checkForChanges()
            self.refreshClipboardHistoryMenu()
        }
        clipboardHistoryMenu.onToggleRecording = { [weak self] in
            guard let self else { return }
            self.clipboardHistory.setEnabled(!self.clipboardHistory.isEnabled)
            self.refreshClipboardHistoryMenu()
        }
        clipboardHistoryMenu.onClear = { [weak self] in self?.clearClipboardHistory() }
        clipboardHistory.start()
        refreshClipboardHistoryMenu()
    }

    private func refreshClipboardHistoryMenu() {
        clipboardHistoryMenu.update(items: clipboardHistoryStore.items,
                                    isEnabled: clipboardHistory.isEnabled,
                                    error: clipboardHistoryStore.lastError)
    }

    private func clearClipboardHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "清除剪貼簿歷史？"
        alert.informativeText = "將刪除保存在這台 Mac 的全部剪貼紀錄。目前可用 ⌘V 貼上的內容不受影響。"
        alert.addButton(withTitle: "清除紀錄")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            clipboardHistoryStore.clear()
            refreshClipboardHistoryMenu()
        }
        NSApp.hide(nil)
    }

    private func configureRemoteInput() {
        remoteBridge.onConnectionChange = { [weak self] status in
            self?.remoteConnectionMenuItem.title = "iPhone 遠端：\(status)"
        }
        remoteBridge.onPairingComplete = { [weak self] phoneName in
            guard let self else { return }
            self.remoteConnectionMenuItem.title = "iPhone 遠端：已配對 \(phoneName)"
            NSSound(named: "Glass")?.play()
        }
        remoteBridge.onMessage = { [weak self] message in
            guard let self, self.isRelayModeEnabled else { return }
            self.remoteTargetController.handle(message) { [weak self] response in
                self?.remoteBridge.send(response) ?? false
            }
        }
        remoteTargetController.onTargetChange = { [weak self] status in
            self?.remoteTargetMenuItem.title = status
        }
        // 這裡刻意不呼叫 remoteBridge.start()。以前它在啟動時就無條件開始廣播，
        // 而且對已配對的手機是零確認自動接受，等於 App 一開就永遠在等手機連進來。
        // 現在只有使用者明確開啟接力模式時才會開始廣播。
    }

    /// Connect presentation only; the coordinator owns recorder and network callbacks.
    private func configureDictation() {
        nekoHUD.onCancel = { [weak self] in self?.dictation.cancel() }
        nekoHUD.onFinish = { [weak self] in self?.dictation.stop() }
        nekoHUD.onStart = { [weak self] in self?.toggleRecording() }
        dictation.onStateChange = { [weak self] state in self?.renderDictationState(state) }
        dictation.onError = { [weak self] message in self?.showError(message) }
        dictation.consumeTranscript = { [weak self] text in self?.consumeCatGreeting(text) ?? false }
        dictation.deliverText = { [weak self] text in self?.insertDictationText(text) ?? false }
        dictation.onRetryRequested = { [weak self] id, message in
            // Defer the modal so the coordinator can finish its transition first.
            DispatchQueue.main.async {
                guard let self, self.dictation.sessionID == id, self.dictation.state == .awaitingRetry else { return }
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "語音辨識未完成"
                alert.informativeText = message
                alert.alertStyle = .warning
                alert.addButton(withTitle: "重新辨識")
                alert.addButton(withTitle: "捨棄錄音")
                let response = alert.runModal()
                NSApp.hide(nil)
                if response == .alertFirstButtonReturn {
                    _ = self.dictation.retry(sessionID: id)
                } else {
                    self.dictation.discard(sessionID: id)
                }
            }
        }
    }

    @objc private func showPairingCode() {
        var randomValue: UInt32 = 0
        let status = withUnsafeMutableBytes(of: &randomValue) { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            showError("無法建立安全配對碼，請再試一次。")
            return
        }

        let code = String(format: "%06u", randomValue % 1_000_000)

        // 配對必須讓 iPhone 找得到這台 Mac，而那需要 Mac 正在廣播。接力模式預設
        // 是關的，如果不在這裡暫時開啟，iPhone 會永遠掃不到 Mac，配對功能等於整個
        // 壞掉——而且因為平常不會重新配對，這種壞法可能很久以後才被發現。
        let relayModeBeforePairing = isRelayModeEnabled
        if !relayModeBeforePairing { setRelayMode(enabled: true, playSound: false) }
        remoteBridge.beginPairing(code: code)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "配對 iPhone"
        var informativeText = "請在 iPhone 的「Mac 連線」中選擇這台 Mac，輸入配對碼：\n\n\(code)\n\n配對碼 5 分鐘後失效。"
        if !relayModeBeforePairing {
            informativeText += "\n\n配對期間會暫時開啟接力模式。關閉這個視窗後會恢復原狀，"
                + "之後要用 iPhone 輸入時，請按 \(shortcutDisplayName(relayHotKey ?? defaultRelayHotKey)) 或從選單列開啟接力模式。"
        }
        alert.informativeText = informativeText
        alert.alertStyle = .informational
        alert.addButton(withTitle: "完成")
        alert.runModal()

        remoteBridge.endPairing()
        // 一律還原成使用者原本選擇的狀態。配對成功就自動留在接力模式，正是這次要
        // 消除的「沒同意就連上手機」，所以寧可讓使用者自己再按一次。
        if !relayModeBeforePairing { setRelayMode(enabled: false, playSound: false) }
        NSApp.hide(nil)
    }

    @objc private func forgetPairedPhone() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "忘記已配對的 iPhone？"
        alert.informativeText = "之後若要使用遠端貼上，必須重新輸入一次配對碼。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "忘記")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            remoteTargetController.clearTarget()
            remoteBridge.forgetPairedPhone()
        }
        NSApp.hide(nil)
    }

    // MARK: - iPhone 接力模式

    func toggleRelayMode() {
        setRelayMode(enabled: !isRelayModeEnabled)
    }

    @objc private func toggleRelayFromMenu() {
        toggleRelayMode()
    }

    /// 開關接力模式。
    ///
    /// 關閉時不只是停止廣播，還會斷開已連線的 iPhone 並清掉已鎖定的輸入框。
    /// 少了後兩步，「關閉」就只是不再接受新連線，既有連線仍能繼續貼字。
    private func setRelayMode(enabled: Bool, playSound: Bool = true) {
        guard isRelayModeEnabled != enabled else { return }
        isRelayModeEnabled = enabled

        if enabled {
            remoteBridge.start()
        } else {
            remoteTargetController.clearTarget()
            remoteBridge.stop()
        }
        updateRelayMenu()
        if playSound { NSSound(named: enabled ? "Glass" : "Pop")?.play() }
    }

    private func relayMenuTitle() -> String {
        guard let relayHotKey else { return "iPhone 接力模式" }
        return "iPhone 接力模式（\(shortcutDisplayName(relayHotKey))）"
    }

    private func updateRelayMenu() {
        relayMenuItem.state = isRelayModeEnabled ? .on : .off
        relayMenuItem.title = relayMenuTitle()
        if !isRelayModeEnabled {
            remoteConnectionMenuItem.title = "iPhone 遠端：已停用"
            remoteTargetMenuItem.title = "尚未鎖定輸入框"
        }
        resetStatus()
    }

    private func loadRelaySettings() {
        let value = settings.loadRelaySettings()
        preferredInputDeviceUID = value.preferredInputDeviceUID
        relayHotKey = value.relayHotKey
    }

    @objc private func showRelaySettingsDialog() {
        NSApp.activate(ignoringOtherApps: true)
        let view = RelaySettingsView(
            relayShortcut: relayHotKey,
            preferredDeviceUID: preferredInputDeviceUID,
            devices: AudioInputDevices.current()
        )
        let alert = NSAlert()
        alert.messageText = "iPhone 接力與麥克風設定"
        alert.alertStyle = .informational
        alert.accessoryView = view
        alert.addButton(withTitle: "儲存")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.hide(nil)
            return
        }

        preferredInputDeviceUID = view.preferredDeviceUID

        relayHotKey = view.relayShortcut
        saveRelayHotKey()
        if registerRelayHotKey() != noErr {
            relayHotKey = nil
            registerRelayHotKey()
            saveRelayHotKey()
            showError("接力模式快捷鍵無法註冊，可能已被其他程式占用。仍可從選單列切換接力模式。")
        }
        updateRelayMenu()
        NSApp.hide(nil)
    }

    private func saveRelayHotKey() {
        settings.saveRelaySettings(RelaySettings(
            preferredInputDeviceUID: preferredInputDeviceUID,
            relayHotKey: relayHotKey
        ))
    }

    /// 註冊接力模式快捷鍵。沒有設定時只是解除註冊，不視為錯誤。
    @discardableResult
    private func registerRelayHotKey() -> OSStatus {
        hotKeys.register(shortcut: relayHotKey, id: HotKeyManager.relayID)
    }

    private func registerHotKey() {
        let installStatus = hotKeys.installHandler { [weak self] id in
            if id == HotKeyManager.relayID { self?.toggleRelayMode() }
            else if id == HotKeyManager.clipboardID { self?.showClipboardPicker() }
            else { self?.toggleRecording(useAlternateMode: id == HotKeyManager.alternateID) }
        }
        let registerStatus = registerCurrentHotKey()
        UpdateDiagnostics.shared.record(.recordingHotKey, succeeded: registerStatus == noErr)
        if let clipboardHotKey {
            let clipboardStatus = hotKeys.register(shortcut: clipboardHotKey, id: HotKeyManager.clipboardID)
            UpdateDiagnostics.shared.record(.clipboardHotKey, succeeded: clipboardStatus == noErr)
            clipboardHotKeyRegistrationFailed = clipboardStatus != noErr
        }
        statusMenu.updateClipboardShortcut(clipboardShortcutTitle)
        if registerRelayHotKey() != noErr {
            relayHotKey = nil
            registerRelayHotKey()
            updateRelayMenu()
        }
        if installStatus != noErr || registerStatus != noErr {
            showError("無法註冊快捷鍵 \(shortcutDisplayName(currentHotKey))。可能已被其他程式使用。")
        }
    }

    private func registerCurrentHotKey() -> OSStatus {
        let status = hotKeys.register(shortcut: currentHotKey, id: HotKeyManager.primaryID)
        registerAlternateHotKey()
        return status
    }

    /// 註冊第二快捷鍵。沒有設定時只是解除註冊，不視為錯誤。
    @discardableResult
    private func registerAlternateHotKey() -> OSStatus {
        hotKeys.register(shortcut: alternateHotKey, id: HotKeyManager.alternateID)
    }

    private func setTextOutputMode(_ mode: TextOutputMode) {
        textOutputMode = mode
        settings.saveOutputMode(mode)
        updateTextOutputModeMenu()
    }

    private func updateTextOutputModeMenu() {
        for (mode, item) in modeMenuItems {
            item.state = mode == textOutputMode ? .on : .off
        }
    }

    @objc private func selectOutputMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = TextOutputMode(rawValue: raw) else { return }
        setTextOutputMode(mode)
    }

    // MARK: - 語言設定

    private func saveLanguageSettings(_ value: LanguageSettings) {
        settings.saveLanguage(value)
        languageSettings = value
    }

    @objc private func showLanguageDialog() {
        NSApp.activate(ignoringOtherApps: true)
        let view = LanguageSettingsView(settings: languageSettings)
        let alert = NSAlert()
        alert.messageText = "語言設定"
        alert.informativeText = "最多三種語言：一個主要語言，加上最多兩個允許混用的語言。"
        alert.alertStyle = .informational
        alert.accessoryView = view
        alert.addButton(withTitle: "儲存")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        saveLanguageSettings(view.currentSettings())
        NSApp.hide(nil)
    }

    // MARK: - 文字與錄音設定

    private func loadTextSettings() {
        let value = settings.loadTextSettings()
        convertChineseNumerals = value.convertChineseNumerals
        silenceAutoStopSeconds = value.silenceAutoStopSeconds
        alternateHotKey = value.alternateHotKey
        alternateOutputMode = value.alternateOutputMode
    }

    @objc private func showTextSettingsDialog() {
        NSApp.activate(ignoringOtherApps: true)
        let view = TextSettingsView(
            convertNumerals: convertChineseNumerals,
            silenceSeconds: silenceAutoStopSeconds,
            alternateShortcut: alternateHotKey,
            alternateMode: alternateOutputMode
        )
        let alert = NSAlert()
        alert.messageText = "文字與錄音設定"
        alert.alertStyle = .informational
        alert.accessoryView = view
        alert.addButton(withTitle: "儲存")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        convertChineseNumerals = view.convertNumerals
        silenceAutoStopSeconds = view.silenceSeconds
        alternateOutputMode = view.alternateMode
        alternateHotKey = view.alternateShortcut
        settings.saveTextSettings(TextSettings(
            convertChineseNumerals: convertChineseNumerals,
            silenceAutoStopSeconds: silenceAutoStopSeconds,
            alternateHotKey: alternateHotKey, alternateOutputMode: alternateOutputMode
        ))
        if registerAlternateHotKey() != noErr {
            showError("第二快捷鍵無法註冊，可能已被其他程式占用。")
        }
        NSApp.hide(nil)
    }

    private func toggleMenuTitle() -> String {
        "開始／停止錄音（\(shortcutDisplayName(currentHotKey))）"
    }

    @objc private func showHotKeyDialog() {
        NSApp.activate(ignoringOtherApps: true)
        let recorder = ShortcutRecorderView(shortcut: currentHotKey)
        let alert = NSAlert()
        alert.messageText = "設定錄音快捷鍵"
        alert.informativeText = "按下你想使用的全域快捷鍵。若與其他 App 衝突，將保留目前設定。"
        alert.alertStyle = .informational
        alert.accessoryView = recorder
        alert.addButton(withTitle: "儲存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = recorder

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applyHotKey(recorder.shortcut)
    }

    private func applyHotKey(_ newHotKey: HotKeyShortcut) {
        guard newHotKey != currentHotKey else { return }
        let previous = currentHotKey

        currentHotKey = newHotKey
        let status = registerCurrentHotKey()
        guard status == noErr else {
            currentHotKey = previous
            _ = registerCurrentHotKey()
            showError("快捷鍵 \(shortcutDisplayName(newHotKey)) 無法使用，可能已被其他程式占用。原設定 \(shortcutDisplayName(previous)) 已保留。")
            return
        }

        settings.saveHotKey(newHotKey)
        toggleMenuItem.title = toggleMenuTitle()
        NSSound(named: "Glass")?.play()
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func showVocabularyWindow() {
        correctionMonitor.stop(reason: "管理詞典中；下一次本機貼上後重新觀察修正。")
        if vocabularyWindow == nil {
            vocabularyWindow = VocabularyWindowController(store: vocabularyStore, learning: vocabularyLearning)
        }
        vocabularyWindow?.present()
    }

    @objc private func showNekoPreview() {
        guard dictation.state == .idle else { return }
        nekoHUD.showPreview(shortcut: shortcutDisplayName(currentHotKey))
        desktopPet.refresh()
    }

    @objc private func toggleDesktopPet() { desktopPet.setReleased(!desktopPet.isReleased) }

    @objc private func showVocabularyPreview() {
        PasteDiagnostics.shared.record(.init(tag: .vocabularyPreviewRequest,
            canStart: dictation.state == .idle,
            state: PasteDiagnostics.State(rawValue: String(describing: dictation.state)),
            learningStage: .begin, isPreview: true))
        guard dictation.state == .idle else { return }
        guard !vocabularyToast.isPresentingLearningPrompt else {
            PasteDiagnostics.shared.record(.init(tag: .vocabularyPreviewRequest, accepted: false,
                learningStage: .begin, learningReason: .candidateUnavailable, isPreview: true))
            return
        }
        correctionMonitor.stop(reason: "正在預覽字典提示；下一次貼上後重新觀察修正。")
        nekoHUD.hide()
        vocabularyToast.showPreview()
    }

    @objc private func showNekoIntroduction() {
        guard dictation.state == .idle else { return }
        nekoHUD.showPreview(shortcut: shortcutDisplayName(currentHotKey), showIntroduction: true)
        desktopPet.refresh()
    }

    @objc private func selectNekoPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let position = NekoHUDPosition(rawValue: raw) else { return }
        nekoHUD.setPosition(position)
        statusMenu.updateNekoPosition(position)
    }

    @objc private func toggleFromMenu() {
        toggleRecording()
    }

    @objc private func showClipboardPicker() {
        guard dictation.state == .idle else { NSSound.beep(); return }
        if clipboardPicker.isVisible { clipboardPicker.dismiss(); desktopPet.refresh(); return }
        clipboardHistory.checkForChanges()
        correctionMonitor.stop(reason: "正在選擇剪貼簿歷史；下一次語音貼上後重新觀察修正。")
        var target: FocusTarget?
        var failure: FocusTargetError?
        do { target = try focusTargets.captureTarget(ttl: 90, policy: .localDictation) }
        catch let error as FocusTargetError { failure = error }
        catch { failure = .noEditableTarget }
        clipboardPicker.show(items: clipboardHistoryStore.items,
                             shortcutTitle: clipboardShortcutTitle,
                             target: target, captureFailure: failure)
        desktopPet.refresh()
    }

    func toggleRecording(useAlternateMode: Bool = false) {
        clipboardPicker.dismiss()
        if PasteDiagnostics.shared.isEnabled {
            var event = PasteDiagnostics.Event(tag: .toggle)
            event.canStart = dictation.canStart
            event.recordingBusy = micRecorder.isBusy
            event.state = PasteDiagnostics.State(rawValue: String(describing: dictation.state))
            PasteDiagnostics.shared.record(event)
        }
        if dictation.state == .recording {
            dictation.stop()
            return
        }
        guard dictation.canStart else { NSSound.beep(); return }
        guard credentials.readAPIKey() != nil else { showAPIKeyDialog(firstRun: false); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            showError("尚未允許麥克風。請到「系統設定 → 隱私權與安全性 → 麥克風」開啟 What's up my neighbor。")
            return
        }
        guard let device = AudioInputDevices.selected(preferredUID: preferredInputDeviceUID) else {
            showError("找不到電腦端麥克風。請接上麥克風；若電腦放得較遠，可手動開啟 iPhone 接力模式，再從手機錄音。")
            return
        }
        correctionMonitor.stop(reason: "錄音中；完成貼上後才開始觀察修正。")
        dictationTarget = nil
        targetCaptureFailure = nil
        do { dictationTarget = try focusTargets.captureTarget(ttl: 600, policy: .localDictation) }
        catch let error as FocusTargetError { targetCaptureFailure = error }
        catch { targetCaptureFailure = .noEditableTarget }
        let snapshot = DictationSettings(
            language: languageSettings,
            outputMode: useAlternateMode ? alternateOutputMode : textOutputMode,
            convertChineseNumerals: convertChineseNumerals,
            silenceAutoStopSeconds: silenceAutoStopSeconds
        )
        _ = dictation.start(deviceUID: device.uid, settings: snapshot)
    }

    @objc private func cancelRecordingFromMenu() { dictation.cancel() }

    @objc private func retryRecordingFromMenu() {
        guard let id = dictation.sessionID else { return }
        _ = dictation.retry(sessionID: id)
    }

    private func renderDictationState(_ state: DictationState) {
        if state != .idle { catOverlay.hide() }
        desktopPet.refresh()
        if PasteDiagnostics.shared.isEnabled {
            var event = PasteDiagnostics.Event(tag: .stateChange)
            event.state = PasteDiagnostics.State(rawValue: String(describing: state))
            PasteDiagnostics.shared.record(event)
        }
        meteringTimer?.invalidate()
        meteringTimer = nil
        nekoHUD.update(state: state)
        statusMenu.retryMenuItem.isEnabled = state == .awaitingRetry
        statusMenu.cancelMenuItem.isEnabled = state != .idle
        switch state {
        case .idle:
            dictationTarget = nil
            targetCaptureFailure = nil
            resetStatus()
        case .starting:
            statusMenu.updateIcon(.processing, description: "準備錄音")
        case .recording:
            statusMenu.updateIcon(.recording, description: "正在錄音")
            NSSound(named: "Tink")?.play()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.nekoHUD.updateMeter(decibels: self.micRecorder.visualPowerLevel)
                self.dictation.checkRecordingLimits()
            }
            meteringTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        case .finalizing:
            statusMenu.updateIcon(.processing, description: "正在完成錄音")
            NSSound(named: "Pop")?.play()
        case .transcribing, .delivering:
            statusMenu.updateIcon(.processing, description: "正在辨識")
        case .awaitingRetry:
            statusMenu.updateIcon(.retry, description: "錄音暫留等待重試")
        }
    }

    private func consumeCatGreeting(_ transcript: String) -> Bool {
        switch catGreeting.consume(transcript) {
        case .notMatched: return false
        case .cooldown: return true
        case .greet:
            nekoHUD.hide()
            catOverlay.showGreeting()
            desktopPet.refresh()
            return true
        }
    }

    @objc private func openCatSettings() {
        do {
            try FileManager.default.createDirectory(at: CatConfiguration.directoryURL, withIntermediateDirectories: true)
            let destination = CatConfiguration.directoryURL.appendingPathComponent("cat.config.json")
            if !FileManager.default.fileExists(atPath: destination.path),
               let sample = Bundle.main.url(forResource: "cat.config", withExtension: "json") {
                try FileManager.default.copyItem(at: sample, to: destination)
            }
            NSWorkspace.shared.open(CatConfiguration.directoryURL)
        } catch { showError("無法開啟貓咪設定資料夾：\(error.localizedDescription)") }
    }

    private func insertDictationText(_ text: String) -> Bool {
        let result = textInsertion.insert(text, target: dictationTarget, captureFailure: targetCaptureFailure)
        switch result {
        case .pasteEventPosted:
            nekoHUD.showResult("文字已送往輸入框", detail: "已複製到剪貼簿，並送出貼上操作")
            if let target = dictationTarget {
                correctionMonitor.beginMonitoringAfterPaste(originalText: text, targetElement: target.snapshot.element as! AXUIElement)
            }
            NSSound(named: "Glass")?.play()
            return true
        case .copiedOnly(let reason):
            nekoHUD.showResult("文字已複製", detail: "請回到輸入框手動貼上")
            vocabularyLearning.report("本次只複製，未驗證貼入範圍，因此不會自動學習；可手動新增詞條。")
            let message: String
            switch reason {
            case .accessibilityDenied:
                message = "文字已複製到剪貼簿，但尚未取得「輔助使用」權限，請手動貼上。"
            case .noEditableTarget, .noTarget:
                message = "文字已複製到剪貼簿。開始錄音時未找到可驗證的輸入框，請先貼上這次文字；下次先點一下要輸入的位置再錄音。"
            case .targetChanged:
                message = "文字已複製到剪貼簿。錄音期間的 App 或輸入框已改變，請在需要的位置手動貼上。"
            case .targetExpired:
                message = "文字已複製到剪貼簿。這次輸入位置已逾時，請手動貼上。"
            case .eventUnavailable:
                message = "文字已複製到剪貼簿，但系統未能建立貼上按鍵，請手動貼上。"
            }
            DispatchQueue.main.async { [weak self] in self?.showError(message) }
            return true
        case .copyFailed:
            return false
        }
    }

    /// Keep the cat identity in every state; relay retains a distinct plus mark.
    private func resetStatus() {
        guard dictation.state == .idle else { return }
        let description = isRelayModeEnabled ? "What's up my neighbor（iPhone 接力已開啟）" : "What's up my neighbor"
        statusMenu.updateIcon(isRelayModeEnabled ? .relay : .idle, description: description)
    }

    @objc private func showAPIKeyFromMenu() {
        showAPIKeyDialog(firstRun: false)
    }

    private func showAPIKeyDialog(firstRun: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let setupView = APIKeySetupView()
        let alert = NSAlert()
        alert.messageText = firstRun ? "歡迎使用 What's up my neighbor" : "設定／更換 Groq API 金鑰"
        alert.informativeText = "這個 App 使用 Groq Whisper 將語音轉成文字。每位使用者都要使用自己的 Groq API Key。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "安全儲存")
        alert.addButton(withTitle: "稍後設定")
        alert.accessoryView = setupView
        alert.window.initialFirstResponder = setupView.keyField

        if alert.runModal() == .alertFirstButtonReturn {
            let key = setupView.keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.hasPrefix("gsk_") && key.count > 20 else {
                showError("這看起來不是有效的 Groq API Key。請確認已完整貼上以 gsk_ 開頭的金鑰。")
                return
            }
            do {
                try credentials.saveAPIKey(key)
                NSSound(named: "Glass")?.play()
                if firstRun {
                    let success = NSAlert()
                    success.messageText = "Groq API Key 已安全儲存"
                    success.informativeText = "現在可在任何文字輸入位置按 \(shortcutDisplayName(currentHotKey)) 開始錄音，再按一次停止並貼上辨識文字。"
                    success.addButton(withTitle: "開始使用")
                    success.runModal()
                }
            } catch {
                showError("無法把金鑰存入鑰匙圈：\(error.localizedDescription)")
            }
        }
    }

    @objc private func openOfficialWebsite() {
        NSWorkspace.shared.open(URL(string: "https://nekonode.cloud")!)
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "What's up my neighbor"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
        resetStatus()
    }
}
