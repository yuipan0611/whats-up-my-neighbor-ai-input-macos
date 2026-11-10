import AVFoundation
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("FAILED (line \(line)): \(message)\n".utf8))
        exit(1)
    }
}

private func describe(_ settings: [String: Any]) -> [String: Int] {
    var result: [String: Int] = [:]
    for (key, value) in settings { if let number = value as? Int { result[key] = number } }
    return result
}

@main
enum AudioSettingsTests {
    static func main() throws {
        testDictationDefaultsAreUnchanged()
        testMeetingSettingsAndLabel()
        try testEncoderAcceptsBothSettings()
        testRecorderConstructors()
        print("Audio settings tests passed (dictation default locked at AAC 16 kHz mono 32 kbps)")
    }

    // 聽寫的錄音格式不能被這次改動悄悄改掉：AAC／16 kHz／單聲道／32000，且沒有多餘的 key。
    static func testDictationDefaultsAreUnchanged() {
        let settings = PinnedMicrophoneRecorder.defaultAudioSettings
        expect(settings.count == 5, "exactly five keys: \(settings.keys.sorted())")
        expect(describe(settings) == [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ], "dictation default must stay AAC / 16000 / 1 ch / 32000 / high")
    }

    static func testMeetingSettingsAndLabel() {
        let settings = describe(MeetingAudio.settings)
        expect(MeetingAudio.settings.count == 5, "five keys")
        expect(settings[AVFormatIDKey] == Int(kAudioFormatMPEG4AAC), "AAC")
        expect(settings[AVSampleRateKey] == 44_100, "44.1 kHz")
        expect(settings[AVNumberOfChannelsKey] == 1, "mono")
        expect(settings[AVEncoderBitRateKey] == 64_000, "64 kbps")
        expect(settings[AVEncoderAudioQualityKey] == AVAudioQuality.high.rawValue, "quality high")
        // frontmatter 的 audio 欄位必須與實際設定一致。
        let derived = "aac-\(settings[AVSampleRateKey]!)-mono-\(settings[AVEncoderBitRateKey]! / 1000)k"
        expect(MeetingAudio.label == derived, "label \(MeetingAudio.label) matches settings (\(derived))")
        expect(describe(MeetingAudio.settings) != describe(PinnedMicrophoneRecorder.defaultAudioSettings), "meeting differs from dictation")
    }

    // 設定要真的是合法的 AAC：用 AVAudioFile 的編碼器實際開檔、寫一秒靜音，再讀回格式。
    // （AVCaptureAudioFileOutput.audioSettings 在沒接上 session 時讀回 nil，無法直接檢查。）
    static func testEncoderAcceptsBothSettings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, settings, rate) in [("dictation", PinnedMicrophoneRecorder.defaultAudioSettings, 16_000.0),
                                       ("meeting", MeetingAudio.settings, 44_100.0)] {
            let url = directory.appendingPathComponent("\(name).m4a")
            do {
                let file = try AVAudioFile(forWriting: url, settings: settings)
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
                buffer.frameLength = buffer.frameCapacity
                try file.write(from: buffer)
            } catch {
                expect(false, "\(name) settings rejected by the AAC encoder: \(error)")
            }
            let written = try AVAudioFile(forReading: url)
            expect(written.fileFormat.sampleRate == rate && written.fileFormat.channelCount == 1,
                   "\(name) file is \(rate) Hz mono, got \(written.fileFormat)")
        }
        expect(AVCaptureAudioFileOutput.availableOutputFileTypes().contains(.m4a), "m4a output available")
    }

    static func testRecorderConstructors() {
        let dictation = PinnedMicrophoneRecorder() // 聽寫那一行的寫法：不傳參數
        let meeting = PinnedMicrophoneRecorder(audioSettings: MeetingAudio.settings)
        expect(!dictation.isBusy && !meeting.isBusy && !dictation.isRecording, "fresh recorders are idle")
    }
}
