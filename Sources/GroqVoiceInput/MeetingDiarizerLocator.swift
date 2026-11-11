import Foundation

/// 說話者辨識「去哪裡找 CLI 與模型」。給 `MeetingDiarizationCoordinator`（Ben）注入用，
/// 測試時換成假的，不需要真的 App bundle 或模型。
protocol MeetingDiarizerLocator {
    /// 打包在 App 內的 meeting-diarizer 可執行檔；找不到、不能執行，或這台機器不是 Apple Silicon 時回傳 nil。
    func executableURL() -> URL?
    /// 兩個模型都已下載並通過大小檢查。
    func modelsReady() -> Bool
}

enum MeetingDiarizerSupport {
    /// 選單在不支援的機器上顯示這句話（功能停用）。
    static let unsupportedMessage = "此功能需要 Apple Silicon"

    /// 這台機器是 Apple Silicon。看硬體而不是目前行程的架構：App 是 universal，
    /// 在 Rosetta 下跑 x86_64 slice 的 Apple Silicon 機器也可以執行 arm64 的 meeting-diarizer。
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}

/// 正式實作：CLI 在 App bundle 的 Contents/Helpers，模型在 Application Support。
///
/// 位置（Apple 對 bundle 內容的慣例）：
///   Contents/Helpers/meeting-diarizer      命令列輔助工具
///   Contents/Frameworks/libsherpa-onnx-c-api.dylib、libonnxruntime.dylib   它依賴的動態庫
struct BundledMeetingDiarizerLocator: MeetingDiarizerLocator {
    static let helperRelativePath = "Contents/Helpers/meeting-diarizer"

    var bundleURL: URL = Bundle.main.bundleURL
    var assets = MeetingDiarizerAssets()
    var isAppleSilicon: () -> Bool = { MeetingDiarizerSupport.isAppleSilicon }
    var fileManager: FileManager = .default

    func executableURL() -> URL? {
        guard isAppleSilicon() else { return nil }
        let url = bundleURL.appendingPathComponent(Self.helperRelativePath)
        return fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }

    func modelsReady() -> Bool { assets.modelsReady() }
}
