import Foundation

/// 下載模型時顯示給使用者的文字（純函式，可測）。視窗本身在 `MeetingDiarizerDownloadController`。
enum MeetingDiarizerDownloadText {
    static let consentTitle = "下載說話者辨識模型"
    static let consentDownloadButton = "下載"
    static let cancelButton = "取消"
    static let retryButton = "重試"
    static let progressTitle = "正在下載說話者辨識模型"

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    /// 第一次使用前的同意說明：要下載什麼、多大、從哪來、存哪裡、怎麼驗證，以及尚未確認的授權。
    static func consentMessage(for models: [MeetingDiarizerModel], directory: URL) -> String {
        let total = models.reduce(Int64(0)) { $0 + $1.downloadBytes }
        var lines = ["會議說話者辨識需要下載 \(models.count) 個模型檔，共約 \(megabytes(total))："]
        for model in models { lines.append("• \(model.name)（約 \(megabytes(model.downloadBytes))）") }
        lines.append("")
        lines.append("來源：github.com/k2-fsa/sherpa-onnx 的 release。每個檔案都用固定的 SHA256 驗證，不符就丟棄、不安裝。")
        lines.append("存放位置：\((directory.path as NSString).abbreviatingWithTildeInPath)")
        lines.append("說話者辨識本身在這台 Mac 上執行。下載只需要這一次；不下載就不能使用這個功能。")
        let notes = models.compactMap(\.licenseNote)
        if !notes.isEmpty {
            lines.append("")
            lines.append("⚠️ 測試版注意：" + notes.joined(separator: "；") + "。")
        }
        return lines.joined(separator: "\n")
    }

    static func progressLine(received: Int64, total: Int64, modelName: String) -> String {
        let percent = total > 0 ? Int((Double(received) / Double(total) * 100).rounded(.down)) : 100
        return "已下載 \(megabytes(received)) / \(megabytes(total))（\(min(100, percent))%）· \(modelName)"
    }

    static func failureMessage(_ failure: Error) -> String {
        (failure.localizedDescription) + "\n\n已下載且驗證通過的檔案會保留，重試只會下載缺少的部分。"
    }
}
