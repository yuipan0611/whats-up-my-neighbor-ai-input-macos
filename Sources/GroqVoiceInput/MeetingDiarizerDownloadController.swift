import AppKit

/// 第一次使用說話者辨識時：徵求同意 → 顯示進度（可取消）→ 失敗時可重試。
/// 下載、驗證、安裝都在 `MeetingDiarizerDownloader`；這裡只有視窗。
/// 完成回呼：模型已就緒回傳 true；使用者取消或放棄重試回傳 false。主執行緒。
final class MeetingDiarizerDownloadController: NSObject {
    private let assets: MeetingDiarizerAssets
    private let makeDownloader: () -> MeetingDiarizerDownloader
    private var downloader: MeetingDiarizerDownloader?
    private var panel: NSPanel?
    private var bar: NSProgressIndicator?
    private var label: NSTextField?

    init(assets: MeetingDiarizerAssets = MeetingDiarizerAssets(),
         makeDownloader: @escaping () -> MeetingDiarizerDownloader = { MeetingDiarizerDownloader() }) {
        self.assets = assets
        self.makeDownloader = makeDownloader
    }

    var isDownloading: Bool { downloader != nil }

    func ensureModels(completion: @escaping (Bool) -> Void) {
        let missing = assets.missingModels()
        guard !missing.isEmpty else { completion(true); return }
        guard !isDownloading else { return }
        guard askConsent(for: missing) else { completion(false); return }
        download(completion)
    }

    // MARK: 流程

    private func download(_ completion: @escaping (Bool) -> Void) {
        showPanel()
        let downloader = makeDownloader()
        self.downloader = downloader
        downloader.start(progress: { [weak self] progress in
            self?.bar?.doubleValue = progress.fraction
            self?.label?.stringValue = MeetingDiarizerDownloadText.progressLine(
                received: progress.receivedBytes, total: progress.totalBytes, modelName: progress.modelName)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.downloader = nil
            self.closePanel()
            switch result {
            case .success:
                completion(true)
            case .failure(.cancelled):
                completion(false)
            case .failure(let failure):
                if self.askRetry(failure) { self.download(completion) } else { completion(false) }
            }
        })
    }

    @objc private func cancelTapped() { downloader?.cancel() }

    // MARK: 視窗

    private func askConsent(for models: [MeetingDiarizerModel]) -> Bool {
        let alert = NSAlert()
        alert.messageText = MeetingDiarizerDownloadText.consentTitle
        alert.informativeText = MeetingDiarizerDownloadText.consentMessage(for: models, directory: assets.modelsDirectory)
        alert.alertStyle = .informational
        alert.addButton(withTitle: MeetingDiarizerDownloadText.consentDownloadButton)
        alert.addButton(withTitle: MeetingDiarizerDownloadText.cancelButton)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func askRetry(_ failure: Error) -> Bool {
        let alert = NSAlert()
        alert.messageText = "說話者辨識模型下載失敗"
        alert.informativeText = MeetingDiarizerDownloadText.failureMessage(failure)
        alert.alertStyle = .warning
        alert.addButton(withTitle: MeetingDiarizerDownloadText.retryButton)
        alert.addButton(withTitle: MeetingDiarizerDownloadText.cancelButton)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showPanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = MeetingDiarizerDownloadText.progressTitle
        panel.isReleasedWhenClosed = false
        panel.level = .floating

        let label = NSTextField(labelWithString: "準備下載…")
        label.frame = NSRect(x: 20, y: 76, width: 380, height: 20)
        label.lineBreakMode = .byTruncatingMiddle

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 52, width: 380, height: 14))
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0

        let cancel = NSButton(title: MeetingDiarizerDownloadText.cancelButton, target: self, action: #selector(cancelTapped))
        cancel.frame = NSRect(x: 320, y: 12, width: 80, height: 30)
        cancel.bezelStyle = .rounded

        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(bar)
        panel.contentView?.addSubview(cancel)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.bar = bar
        self.label = label
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
        bar = nil
        label = nil
    }
}
