import AppKit

/// 會議說話者辨識的兩個對話框（隱私說明、選人數）。從 `VoiceTypeController` 純搬移出來，
/// 只建立視窗、不執行，方便測試與離線渲染。行為與文字由這裡唯一決定。
enum MeetingDiarizationDialogs {
    /// 打開開關前的說明。`modelsNeedDownload`：模型還沒下載時才提醒接下來會要求下載。
    static func privacyAlert(modelsNeedDownload: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "開啟會議說話者辨識（實驗）？"
        var text = "開啟後，之後的會議錄音檔會保留到說話者辨識完成才刪除；辨識失敗時會一直保留，直到你從選單刪除。"
            + "保留的音檔只存放在這台 Mac 的會議資料夾，說話者辨識也在這台 Mac 上執行。"
        text += "\n\n語音轉文字仍照原本方式處理，會議錄音依舊會送到 Groq，這一點沒有改變。"
        if modelsNeedDownload {
            text += "\n\n接下來會請你下載約 \(MeetingDiarizerDownloadText.megabytes(MeetingDiarizerModelCatalog.totalDownloadBytes)) 的模型（只需要下載一次）。"
        }
        text += "\n\n關閉時維持原本「辨識成功就刪音檔」。"
        alert.informativeText = text
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "開啟")
        alert.addButton(withTitle: "取消")
        return alert
    }

    /// 會議剛結束，問說話人數。回傳視窗與下拉選單（用 `choice(from:)` 取結果）。
    static func speakerCountAlert(last: SpeakerCountChoice?) -> (alert: NSAlert, popup: NSPopUpButton) {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 26), pullsDown: false)
        for count in SpeakerCountChoice.supportedCounts { popup.addItem(withTitle: "\(count) 人") }
        popup.addItem(withTitle: "不確定")
        switch last ?? .count(2) {
        case .count(let n): popup.selectItem(at: n - SpeakerCountChoice.supportedCounts.lowerBound)
        case .auto: popup.selectItem(at: SpeakerCountChoice.supportedCounts.count)
        }
        let alert = NSAlert()
        alert.messageText = "這場會議有幾個人說話？"
        alert.informativeText = "知道人數時分得比較準；選「不確定」會自動估計，可能不準。\n\n"
            + "辨識在背景進行，1 小時的會議約需 10 分鐘以上。\n"
            + "按「略過」時音檔會保留，可以稍後從選單重新辨識或刪除。"
        alert.icon = NSApp.applicationIconImage
        alert.accessoryView = popup
        alert.addButton(withTitle: "開始辨識")
        alert.addButton(withTitle: "略過")
        return (alert, popup)
    }

    static func choice(from popup: NSPopUpButton) -> SpeakerCountChoice {
        let index = popup.indexOfSelectedItem
        return index >= SpeakerCountChoice.supportedCounts.count
            ? .auto : .count(SpeakerCountChoice.supportedCounts.lowerBound + index)
    }
}
