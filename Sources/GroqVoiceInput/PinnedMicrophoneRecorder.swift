import AVFoundation
import Foundation

/// 鎖定指定輸入裝置的錄音器。
///
/// 取代 `AVAudioRecorder` 的理由只有一個：`AVAudioRecorder` 沒有辦法指定錄音裝置，
/// 一律吃系統預設輸入。當 macOS 把預設輸入切到 iPhone 的連續互通麥克風時，
/// 使用者按下快捷鍵只會錄到一段靜音，而且遠處的手機還會被叫醒。
/// `AVCaptureSession` 可以明確指定 `AVCaptureDevice`，完全不受系統預設影響，
/// 也不需要去改動系統設定（那會連 Zoom、Teams 一起改掉）。
///
/// 兩個與 `AVAudioRecorder` 不同、呼叫端必須配合的行為：
///
/// 1. **開始是非同步的。**`AVCaptureSession.startRunning()` 要 100–300ms。
///    `onRecordingStarted` 是在檔案真的開始寫入時才觸發，呼叫端應該在那裡才
///    播提示音，否則使用者聽到聲音就開講，第一個字會被吃掉。
/// 2. **結束也是非同步的。**`stopRecording()` 之後檔案還在背景收尾，必須等
///    `onRecordingFinished` 才能上傳，否則會傳出一個不完整的檔案。
final class PinnedMicrophoneRecorder: NSObject, DictationRecording {
    /// 檔案真的開始寫入時觸發。主執行緒。
    var onRecordingStarted: ((URL) -> Void)?
    /// 檔案完全寫完時觸發。主執行緒。error 非 nil 表示這段錄音不可用。
    var onRecordingFinished: ((URL, Error?) -> Void)?
    /// 還沒開始錄就失敗時觸發（裝置不見了、權限被撤銷等）。主執行緒。
    var onStartFailed: ((URL, Error) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioFileOutput()
    /// 設定與啟停一律在這條序列佇列上做，避免卡住主執行緒，也避免競態。
    private let sessionQueue = DispatchQueue(label: "tw.panh.FreeVoiceType.capture")
    private var configuredDeviceUID: String?
    /// Main-thread ownership lasts through didFinish, including file finalization.
    private var activeRecordingURL: URL?

    /// 錄音採用的編碼設定，與改用 `AVCaptureSession` 之前完全相同，
    /// 上傳給 Groq 的音檔格式因此不變。
    static let defaultAudioSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    /// 預設值就是聽寫一直在用的 32 kbps 設定；只有會議錄音會傳入不同的設定。
    init(audioSettings: [String: Any] = PinnedMicrophoneRecorder.defaultAudioSettings) {
        super.init()
        output.audioSettings = audioSettings
    }

    /// 啟動、錄音及檔案收尾期間都忙碌；取消也必須等原錄音完成收尾。
    var isBusy: Bool { activeRecordingURL != nil || output.isRecording }

    var isRecording: Bool { output.isRecording }

    /// 目前的平均音量（dBFS），與 `AVAudioRecorder.averagePower(forChannel:)` 同單位，
    /// 所以靜音偵測的門檻值可以直接沿用。
    ///
    /// 量不到時回傳 0（等同最大音量）而不是 -160：靜音自動停止寧可不觸發，
    /// 也不要因為讀不到音量就把使用者講到一半的話切掉。
    var averagePowerLevel: Float {
        output.connection(with: .audio)?.audioChannels.first?.averagePowerLevel ?? 0
    }

    /// Presentation must distinguish missing measurements from maximum volume.
    /// Keep the conservative silence-auto-stop fallback above unchanged.
    // 雙軌計量設計：
    // averagePowerLevel 採保守容錯策略（量不到回傳 0 代表大聲，絕不因量測失效誤切靜音）；
    // visualPowerLevel 則回傳 Float?，讓 UI 能明確區分「未錄音/訊號中斷（nil）」與「最大音量」，避免波形錯誤顯示全滿。
    var visualPowerLevel: Float? {
        guard isRecording else { return nil }
        return output.connection(with: .audio)?.audioChannels.first?.averagePowerLevel
    }

    func start(deviceUID: String, url: URL) {
        guard !isBusy else { return }
        activeRecordingURL = url

        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureIfNeeded(deviceUID: deviceUID)
            } catch {
                DispatchQueue.main.async {
                    guard self.activeRecordingURL == url else { return }
                    self.activeRecordingURL = nil
                    self.onStartFailed?(url, error)
                }
                return
            }

            if !self.session.isRunning { self.session.startRunning() }

            guard self.session.isRunning else {
                DispatchQueue.main.async {
                    guard self.activeRecordingURL == url else { return }
                    self.activeRecordingURL = nil
                    self.onStartFailed?(url, VoiceTypeError.message("無法啟動錄音裝置。"))
                }
                return
            }

            // A concurrent cancellation queues shutdown after this block. Keep the
            // URL busy until the matching finish callback has released the file.
            self.output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
        }
    }

    func stop() {
        guard output.isRecording else { return }
        output.stopRecording()
    }

    /// 取消或 App 結束時呼叫；排在啟動後停止，避免尚未開始就漏掉取消。
    func shutdown() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.output.isRecording { self.output.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// 只在選中的裝置改變時重新設定。設定本身是最貴的一步，留著重複使用，
    /// 第二次之後的 `startRunning()` 會明顯比第一次快。
    private func configureIfNeeded(deviceUID: String) throws {
        // 硬體重新插拔防護：
        // 麥克風拔除後再插回時 UID 不變，但底層 captureSession 的 input 會被 macOS 系統自動移除。
        // 若只比對 UID 就會誤判為已設定而跳過加入 input，導致錄出無聲空檔；因此必須同時檢查 session.inputs.isEmpty。
        // 也檢查 inputs 是否還在：裝置被拔掉再插回來時 UID 沒變，但 session 的
        // input 已經被系統移掉了，只比對 UID 會跳過重建而錄到一段空的音訊。
        guard configuredDeviceUID != deviceUID || session.inputs.isEmpty else { return }

        // 正常情況下一定支援（實機驗證過），但萬一不支援，`startRecording` 會丟出
        // Objective-C 例外直接讓 App 當掉。先擋下來換成一般錯誤訊息。
        guard AVCaptureAudioFileOutput.availableOutputFileTypes().contains(.m4a) else {
            throw VoiceTypeError.message("這台 Mac 不支援 m4a 錄音格式。")
        }

        guard let device = AVCaptureDevice(uniqueID: deviceUID) else {
            throw VoiceTypeError.message("找不到指定的錄音裝置，請重新選擇麥克風。")
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        for existing in session.inputs { session.removeInput(existing) }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw VoiceTypeError.message("無法使用「\(device.localizedName)」錄音。")
        }
        session.addInput(input)

        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw VoiceTypeError.message("無法建立錄音輸出。")
            }
            session.addOutput(output)
        }
        session.commitConfiguration()

        configuredDeviceUID = deviceUID
    }

    /// 錄完就把 session 停掉。留著跑雖然能讓下一次更快，但選單列的麥克風
    /// 使用中指示會一直亮著，那是不能接受的隱私表現。
    private func stopSessionAfterRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }
}

extension PinnedMicrophoneRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeRecordingURL == fileURL else { return }
            self.onRecordingStarted?(fileURL)
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // 錄音正常結束時 error 仍可能非 nil（例如達到長度上限）。
        // AVFoundation 用 AVErrorRecordingSuccessfullyFinishedKey 告訴我們
        // 檔案到底能不能用，不看這個旗標會把可用的錄音誤丟掉。
        // 容錯判斷：達到錄音長度上限或外部正常停止時，AVFoundation 仍會傳入非 nil 的 NSError；
        // 必須以 AVErrorRecordingSuccessfullyFinishedKey 為準，避免將已成功寫入的音檔誤判為失敗而丟棄。
        let recordingIsUsable: Bool
        if let error = error as NSError? {
            recordingIsUsable = (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
        } else {
            recordingIsUsable = true
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.activeRecordingURL == outputFileURL {
                // Enqueue the old session's stop before accepting another start.
                // A delayed callback for another URL must never stop a new job.
                self.stopSessionAfterRecording()
                self.activeRecordingURL = nil
            }
            self.onRecordingFinished?(outputFileURL, recordingIsUsable ? nil : error)
        }
    }
}
