import AVFoundation

/// 會議錄音的編碼設定：AAC、44.1 kHz、單聲道、64 kbps（約 2.4 MB／5 分鐘）。
///
/// 為什麼比聽寫高：說話者辨識在本機用這份錄音，AMI 10 分鐘 4 人的比較中，
/// AAC 16k/32k 準確率 72.4%、16k/48k 86.6%、44.1k/64k 94.8%。
/// Groq 端仍收 m4a，上傳流程不變。聽寫繼續用 `PinnedMicrophoneRecorder.defaultAudioSettings`。
enum MeetingAudio {
    /// 寫進 transcript.md frontmatter 的 `audio:` 欄位。改設定時要一起改，測試會比對。
    static let label = "aac-44100-mono-64k"

    static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]
}
