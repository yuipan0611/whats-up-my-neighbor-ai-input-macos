import AppKit
import Sparkle
import UserNotifications

// MARK: - Sparkle 自動更新控制器
// 負責與 Sparkle 2 更新框架進行整合協調。
// 核心設計原則：
// 1. Sparkle 擁有驗證（EdDSA 簽名）、下載與替換二進位檔案的權責。
// 2. 本控制器只管理「提醒」時機，堅決不搶奪使用者當前的語音聽寫輸入焦點。
// 3. 延後重啟：若使用者或 Sparkle 準備重啟以套用更新，但當前正在錄音或重試（isBusy），
//    將 relaunchHandler 扣留並暫緩重啟，待語音工作徹底完成後才釋放執行。

/// Sparkle owns validation, download and replacement. This adapter only manages
/// reminders and defers UI/relaunch until dictation and retry work is finished.
final class AppUpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, UNUserNotificationCenterDelegate {
    private static let notificationID = "tw.panh.FreeVoiceType.update"
    private let isBusy: () -> Bool
    private var controller: SPUStandardUpdaterController!
    private var reminder = UpdateReminderPolicy()
    private var timer: Timer?
    private var relaunchHandler: (() -> Void)?
    private var notificationQueryInFlight = false
    private var requestedNotificationPermission = false
    private weak var menuItem: NSMenuItem?
    private weak var automaticCheckItem: NSMenuItem?

    init(isBusy: @escaping () -> Bool) {
        self.isBusy = isBusy
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    func addMenuItems(to menu: NSMenu) {
        let item = NSMenuItem(title: "檢查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        menuItem = item
        let automatic = NSMenuItem(title: "自動偵測新版本", action: #selector(toggleAutomaticChecks), keyEquivalent: "")
        automatic.target = self
        menu.addItem(automatic)
        automaticCheckItem = automatic
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        controller.startUpdater()
        OldAppBackupCleanup.schedule()
        UpdateDiagnostics.shared.record(.updaterStarted)
        automaticCheckItem?.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
        // A launch check is asynchronous, quiet on network errors, and still
        // respects Sparkle's last-check scheduling and the user's preference.
    }

    @objc private func toggleAutomaticChecks() {
        controller.updater.automaticallyChecksForUpdates.toggle()
        automaticCheckItem?.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        UpdateDiagnostics.shared.record(.manualCheck)
        reminder.requestPresentation()
        if isBusy() {
            menuItem?.title = "工作完成後檢查更新…"
            scheduleReminder()
        } else {
            processReminder(notificationsAllowed: false)
        }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !isBusy() else {
            throw NSError(domain: "tw.panh.FreeVoiceType.update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "語音工作尚未完成，稍後再檢查更新。"])
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    // 拒絕 Sparkle 在排程檢查到更新時直接彈窗：
    // 回傳 false 讓更新資訊交由本控制器的 reminder 機制處理，避免使用者開機或日常打字時突然被更新彈窗搶走焦點。
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false // Reminder first; never steal dictation focus near app launch.
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        reminder.receive(version: update.displayVersionString)
        UpdateDiagnostics.shared.record(.updateDetected, version: update.displayVersionString)
        menuItem?.title = "有新版本 \(update.displayVersionString)…"
        scheduleReminder()
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        clearReminder()
    }

    func standardUserDriverWillFinishUpdateSession() {
        UpdateDiagnostics.shared.record(.sessionFinished)
        clearReminder()
    }

    // 若當前正處於語音錄音或重試中（isBusy），暫緩 Sparkle 的即時重啟，
    // 將 installHandler 暫存至 relaunchHandler，待工作完畢後再觸發重啟。
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        relaunchHandler = installHandler
        UpdateDiagnostics.shared.record(.relaunchDeferred)
        menuItem?.title = "工作完成後重新啟動以更新…"
        scheduleReminder()
        return true
    }

    private func scheduleReminder() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard !isBusy() else { return }
        if let handler = relaunchHandler {
            UpdateDiagnostics.shared.record(.relaunchStarted)
            relaunchHandler = nil
            stopTimer()
            handler()
            return
        }
        guard !notificationQueryInFlight else { return }
        notificationQueryInFlight = true
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationQueryInFlight = false
                UpdateDiagnostics.shared.record(.notificationPermission, authorization: settings.authorizationStatus.rawValue)
                guard !self.isBusy() else { return }
                // Ask only when there is an actual update, after voice work is
                // done. Denial has an in-app prompt and menu fallback.
                if settings.authorizationStatus == .notDetermined,
                   self.reminder.version != nil, !self.requestedNotificationPermission {
                    self.requestedNotificationPermission = true
                    self.notificationQueryInFlight = true
                    center.requestAuthorization(options: [.alert]) { _, _ in
                        DispatchQueue.main.async { [weak self] in self?.notificationQueryInFlight = false }
                    }
                    return
                }
                self.processReminder(notificationsAllowed: settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            }
        }
    }

    private func processReminder(notificationsAllowed: Bool) {
        switch reminder.nextAction(isBusy: isBusy(), notificationsAllowed: notificationsAllowed) {
        case .none: break
        case .showUpdate:
            stopTimer()
            controller.checkForUpdates(nil) // Presents choices; does not install.
        case .notify:
            stopTimer()
            let content = UNMutableNotificationContent()
            content.title = "語音輸入有新版本 \(reminder.version ?? "")"
            content.body = "點選查看更新內容，再決定是否下載安裝。也可從選單列選擇檢查更新。"
            let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { [weak self] error in
                UpdateDiagnostics.shared.record(.notificationQueued, succeeded: error == nil)
                guard error != nil else { return }
                DispatchQueue.main.async {
                    guard let self, self.reminder.version != nil else { return }
                    self.reminder.requestPresentation()
                    self.scheduleReminder()
                }
            }
        }
    }

    private func clearReminder() {
        reminder.clear()
        menuItem?.title = "檢查更新…"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        if relaunchHandler == nil { stopTimer() }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == Self.notificationID,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { [weak self] in self?.checkForUpdates() }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    deinit { timer?.invalidate() }
}
