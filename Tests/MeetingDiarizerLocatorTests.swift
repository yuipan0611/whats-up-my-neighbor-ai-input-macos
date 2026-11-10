import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("FAILED (line \(line)): \(message)\n".utf8))
        exit(1)
    }
}

private func makeFile(_ url: URL, bytes: Int64, executable: Bool = false) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(bytes)) // 稀疏檔：不真的佔 28 MB
    try handle.close()
    try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
}

@main
enum MeetingDiarizerLocatorTests {
    static func main() throws {
        try testLocatorFindsHelperOnlyOnAppleSilicon()
        try testModelsReadyChecksBothFilesAndSizes()
        testCatalogIsPinnedAndFlagsUnconfirmedLicense()
        testDefaultLocationsAndSupportMessage()
        testDownloadTextTellsTheUserWhatTheyAreAgreeingTo()
        print("Meeting diarizer locator tests passed (5 scenarios)")
    }

    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingDiarizerLocatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func testLocatorFindsHelperOnlyOnAppleSilicon() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("App.app", isDirectory: true)
        let assets = MeetingDiarizerAssets(modelsDirectory: root.appendingPathComponent("models"))
        var locator = BundledMeetingDiarizerLocator(bundleURL: app, assets: assets, isAppleSilicon: { true })
        expect(locator.executableURL() == nil, "no helper in the bundle yet")

        let helper = app.appendingPathComponent("Contents/Helpers/meeting-diarizer")
        try makeFile(helper, bytes: 10, executable: false)
        expect(locator.executableURL() == nil, "a non-executable file is not a usable helper")
        try makeFile(helper, bytes: 10, executable: true)
        expect(locator.executableURL() == helper, "found at Contents/Helpers/meeting-diarizer")

        locator.isAppleSilicon = { false }
        expect(locator.executableURL() == nil, "Intel Mac: the feature is disabled even though the helper is bundled")
    }

    static func testModelsReadyChecksBothFilesAndSizes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = MeetingDiarizerAssets(modelsDirectory: root.appendingPathComponent("models"))
        let locator = BundledMeetingDiarizerLocator(bundleURL: root, assets: assets, isAppleSilicon: { true })
        let models = MeetingDiarizerModelCatalog.all
        expect(!locator.modelsReady() && assets.missingModels() == models, "nothing installed")

        try makeFile(assets.installedURL(for: models[0]), bytes: models[0].installedBytes)
        expect(!locator.modelsReady() && assets.missingModels() == [models[1]], "only the segmentation model")

        try makeFile(assets.installedURL(for: models[1]), bytes: models[1].installedBytes - 1)
        expect(!locator.modelsReady(), "a truncated model is not ready")
        try makeFile(assets.installedURL(for: models[1]), bytes: models[1].installedBytes)
        expect(locator.modelsReady() && assets.missingModels().isEmpty, "both installed with the expected sizes")

        // 同名資料夾不是模型檔。
        try FileManager.default.removeItem(at: assets.installedURL(for: models[0]))
        try FileManager.default.createDirectory(at: assets.installedURL(for: models[0]), withIntermediateDirectories: true)
        expect(!assets.isInstalled(models[0]), "a directory is not a model file")
    }

    static func testCatalogIsPinnedAndFlagsUnconfirmedLicense() {
        let models = MeetingDiarizerModelCatalog.all
        expect(models.count == 2, "segmentation + speaker embedding")
        for model in models {
            expect(model.url.scheme == "https" && model.url.host == "github.com" && model.url.path.hasPrefix("/k2-fsa/sherpa-onnx/releases/download/"),
                   "\(model.name): pinned GitHub release URL")
            for hash in [model.downloadSHA256, model.installedSHA256] {
                expect(hash.count == 64 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(model.name): lowercase SHA256 hex")
            }
            expect(model.downloadBytes > 0 && model.installedBytes > 0 && model.installedBytes <= model.downloadBytes * 2, "\(model.name): plausible sizes")
            expect(!model.installPath.hasPrefix("/") && !model.installPath.contains(".."), "\(model.name): relative install path inside models/")
        }
        // 兩個檔案要是 meeting-diarizer --models 目錄預期的位置（Tools/MeetingDiarizer/main.swift 的說明）。
        expect(models.map(\.installPath) == ["pyannote-segmentation/model.onnx", "speaker-embedding.onnx"], "layout expected by meeting-diarizer")
        expect(models[0].licenseNote == nil, "segmentation model: MIT notice read in the tarball")
        expect(models[1].licenseNote?.contains("發布前必須確認") == true, "CAM++ license is flagged as must-confirm-before-release")
        expect(MeetingDiarizerModelCatalog.totalDownloadBytes == 35_239_608, "total download size shown to the user")
    }

    static func testDefaultLocationsAndSupportMessage() {
        let path = MeetingDiarizerAssets.defaultModelsDirectory.path
        expect(path.hasSuffix("/Library/Application Support/tw.panh.FreeVoiceType/models"), "default models directory: \(path)")
        expect(MeetingDiarizerSupport.unsupportedMessage == "此功能需要 Apple Silicon", "unsupported hardware message")
        #if arch(arm64)
        expect(MeetingDiarizerSupport.isAppleSilicon, "this test machine is Apple Silicon")
        #endif
    }

    static func testDownloadTextTellsTheUserWhatTheyAreAgreeingTo() {
        let directory = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/tw.panh.FreeVoiceType/models")
        let message = MeetingDiarizerDownloadText.consentMessage(for: MeetingDiarizerModelCatalog.all, directory: directory)
        expect(message.contains("2 個模型檔，共約 35.2 MB"), "total size: \(message)")
        expect(message.contains("pyannote-segmentation-3.0（約 7.0 MB）") && message.contains("CAM++ zh_en 16k（約 28.3 MB）"), "each file and its size")
        expect(message.contains("SHA256") && message.contains("github.com/k2-fsa/sherpa-onnx"), "source and verification")
        expect(message.contains("~/Library/Application Support/tw.panh.FreeVoiceType/models"), "location, abbreviated: \(message)")
        expect(message.contains("發布前必須確認"), "the unconfirmed CAM++ license is shown to the tester")
        let confirmed = MeetingDiarizerDownloadText.consentMessage(for: [MeetingDiarizerModelCatalog.all[0]], directory: directory)
        expect(!confirmed.contains("⚠️"), "no warning when every license is confirmed")
        expect(MeetingDiarizerDownloadText.progressLine(received: 12_300_000, total: 35_239_608) == "已下載 12.3 MB / 35.2 MB（34%）", "progress line (model name is on its own line)")
        expect(MeetingDiarizerDownloadText.progressLine(received: 5, total: 0).contains("100%"), "no division by zero")
        expect(MeetingDiarizerDownloadText.failureMessage(MeetingDiarizerDownloader.Failure.checksumMismatch(model: "m")).contains("重試只會下載缺少的部分"), "retry hint")
    }
}
