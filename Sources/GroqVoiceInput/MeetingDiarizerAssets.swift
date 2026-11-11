import Foundation

/// 說話者辨識需要的兩個模型：清單、安裝位置與「是否已就緒」的檢查。
/// 下載與驗證在 `MeetingDiarizerDownloader`；這裡只有純資料與檔案檢查，不碰網路。
///
/// 模型不進 repo、不進安裝包：第一次使用會議說話者辨識時，徵求使用者同意後才下載
/// （安裝包因此不「散布」模型，授權風險最小，也不增加安裝包大小）。
struct MeetingDiarizerModel: Equatable {
    enum Source: Equatable {
        /// 下載的檔案就是模型本身。
        case file
        /// 下載的是 tar.bz2；`member` 是壓縮檔內要取出的檔案路徑。
        case archive(member: String)
    }

    let name: String
    let url: URL
    let source: Source
    /// 下載檔（壓縮檔或模型檔）的 SHA256 與大小。
    let downloadSHA256: String
    let downloadBytes: Int64
    /// 安裝到 models 資料夾之後的相對路徑（meeting-diarizer 的 `--models` 目錄內的位置）。
    let installPath: String
    /// 安裝後的模型檔 SHA256 與大小。`modelsReady()` 只比對大小（便宜）；下載時兩者都驗。
    let installedSHA256: String
    let installedBytes: Int64
    /// 授權說明（顯示在下載同意視窗，完整文字見 docs/THIRD-PARTY-MODELS.md）；nil 表示不顯示。
    let licenseNote: String?
}

enum MeetingDiarizerModelCatalog {
    /// 網址、雜湊與大小以 `scripts/fetch-meeting-diarizer-assets.sh`（Ben，#49）為準；
    /// 安裝後檔案的雜湊／大小是用同一份下載解開後量得。release tag 是可變的，所以雜湊寫死在程式裡。
    static let all: [MeetingDiarizerModel] = [
        MeetingDiarizerModel(
            name: "pyannote-segmentation-3.0",
            url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2")!,
            source: .archive(member: "sherpa-onnx-pyannote-segmentation-3-0/model.onnx"),
            downloadSHA256: "24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488",
            downloadBytes: 6_958_444,
            installPath: "pyannote-segmentation/model.onnx",
            installedSHA256: "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079",
            installedBytes: 5_992_913,
            // tarball 內 LICENSE 為 MIT（Copyright 2022 CNRS）；這是 sherpa-onnx 轉出版本隨附的授權聲明。
            licenseNote: "MIT（pyannote-segmentation-3.0，Copyright 2022 CNRS；sherpa-onnx 轉出版本隨附 LICENSE）"),
        MeetingDiarizerModel(
            name: "3D-Speaker CAM++ zh_en 16k",
            // 網址裡的 "recongition" 拼字就是 sherpa-onnx release tag 的名稱，不是筆誤。
            url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx")!,
            source: .file,
            downloadSHA256: "aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2",
            downloadBytes: 28_281_164,
            installPath: "speaker-embedding.onnx",
            installedSHA256: "aa3cfc16963a10586a9393f5035d6d6b57e98d358b347f80c2a30bf4f00ceba2",
            installedBytes: 28_281_164,
            // 授權已確認：ModelScope 官方 API（https://modelscope.cn/api/v1/models/iic/speech_campplus_sv_zh_en_16k-common_advanced)
            // 的 License 欄位為 Apache License 2.0（模型 README frontmatter 同，最後更新 2024-06-24）；
            // 3D-Speaker 主 repo 也是 Apache-2.0。sherpa-onnx 的 ONNX 檔由這個模型轉換而來。
            licenseNote: "Apache License 2.0（3D-Speaker／ModelScope iic/speech_campplus_sv_zh_en_16k-common_advanced；ONNX 版本由 sherpa-onnx 轉換）"),
    ]

    static var totalDownloadBytes: Int64 { all.reduce(0) { $0 + $1.downloadBytes } }
}

struct MeetingDiarizerAssets {
    let modelsDirectory: URL
    /// 需要的模型。正式環境永遠是 `MeetingDiarizerModelCatalog.all`；測試才會換成小檔案。
    let models: [MeetingDiarizerModel]
    private let fileManager: FileManager

    /// 預設：~/Library/Application Support/tw.panh.FreeVoiceType/models
    /// （與 CatConfiguration 同一個 App 資料夾，以 bundle id 命名，不受顯示名稱更改影響）。
    static var defaultModelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tw.panh.FreeVoiceType", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    init(modelsDirectory: URL = MeetingDiarizerAssets.defaultModelsDirectory,
         models: [MeetingDiarizerModel] = MeetingDiarizerModelCatalog.all,
         fileManager: FileManager = .default) {
        self.modelsDirectory = modelsDirectory
        self.models = models
        self.fileManager = fileManager
    }

    func installedURL(for model: MeetingDiarizerModel) -> URL {
        modelsDirectory.appendingPathComponent(model.installPath)
    }

    /// 兩個模型都已安裝，且大小與預期相同（不重算雜湊：這個檢查會在選單開啟時呼叫）。
    func modelsReady() -> Bool {
        models.allSatisfy { isInstalled($0) }
    }

    func isInstalled(_ model: MeetingDiarizerModel) -> Bool {
        let path = installedURL(for: model).path
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value == model.installedBytes
    }

    /// 磁碟上有沒有任何已安裝的模型檔（不看大小；「刪除模型」選單用）。
    var hasInstalledFiles: Bool {
        models.contains { fileManager.fileExists(atPath: installedURL(for: $0).path) }
    }

    /// 「刪除說話者辨識模型」只有在功能關閉、沒有辨識進行中、而且確實有檔案時才能用。
    func canDeleteModels(featureEnabled: Bool, diarizationBusy: Bool) -> Bool {
        !featureEnabled && !diarizationBusy && hasInstalledFiles
    }

    /// 刪除已安裝的模型檔與下載中斷留下的 `.download-*` 暫存資料夾。只刪這份清單裡的檔案與暫存，
    /// 不遞迴刪整個 models 資料夾（裡面若有別的東西不動）；子資料夾與 models 資料夾本身在空了之後才移除。
    /// 回傳刪掉的模型檔數。
    @discardableResult
    func deleteInstalledModels() -> Int {
        var removed = 0
        for model in models {
            let url = installedURL(for: model)
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
            removeIfEmpty(url.deletingLastPathComponent())
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: modelsDirectory.path)) ?? []
        for name in names where name.hasPrefix(".download-") {
            try? fileManager.removeItem(at: modelsDirectory.appendingPathComponent(name))
        }
        removeIfEmpty(modelsDirectory)
        return removed
    }

    private func removeIfEmpty(_ directory: URL) {
        guard let items = try? fileManager.contentsOfDirectory(atPath: directory.path), items.isEmpty else { return }
        try? fileManager.removeItem(at: directory)
    }

    /// 還沒安裝的模型（下載器只會下載這些）。
    func missingModels() -> [MeetingDiarizerModel] {
        models.filter { !isInstalled($0) }
    }
}
