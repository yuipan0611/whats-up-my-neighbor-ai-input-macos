import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class OfficePanelModel: ObservableObject {
    @Published var hostAlias = "neighbor-vps"
    @Published private(set) var message = "按下連線，進入 VPS 上的貓咪辦公室。"
    @Published private(set) var ready = false
    @Published private(set) var connecting = false
    @Published private(set) var pageURL: URL?
    private let tunnel = SSHTunnelController()
    private var checkTask: Task<Void, Never>?
    private var generation = UUID()
    @Published private(set) var ownsTunnel = false
    static let base = URL(string: "http://127.0.0.1:18421")!

    init() {
        tunnel.onStateChange = { [weak self] state in
            guard let self else { return }
            if case .failed(let text) = state {
                self.message = text; self.ready = false; self.connecting = false
                self.ownsTunnel = false
                self.checkTask?.cancel()
            }
        }
    }

    private func healthy() async -> Bool {
        var request = URLRequest(url: Self.base.appendingPathComponent("api/health"))
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["service"] as? String == "neighbor-office",
                  value["version"] as? String == "0.2.0",
                  value["worker_running"] as? Bool == true else { return false }
            return true
        } catch { return false }
    }

    func connect() {
        guard !connecting else { return }
        checkTask?.cancel()
        let token = UUID(); generation = token
        connecting = true; ready = false
        message = "正在確認辦公室服務…"
        checkTask = Task { [weak self] in
            guard let self else { return }
            let existing = await self.healthy()
            guard !Task.isCancelled, self.generation == token else { return }
            if !existing && !self.ownsTunnel {
                do {
                    try self.tunnel.start(configuration: SSHTunnelConfiguration(hostAlias: self.hostAlias))
                    self.ownsTunnel = self.tunnel.state.isActive
                    if !self.ownsTunnel { self.connecting = false; return }
                } catch {
                    self.message = error.localizedDescription; self.connecting = false; return
                }
            }
            for _ in 0..<15 {
                let available: Bool
                if existing { available = true } else { available = await self.healthy() }
                guard !Task.isCancelled, self.generation == token else { return }
                if available {
                    self.ready = true; self.connecting = false
                    self.pageURL = Self.base
                    self.message = self.ownsTunnel ? "已驗證 VPS 辦公室連線" : "已驗證並沿用現有辦公室連線"
                    await self.monitor(token)
                    return
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            self.message = "無法確認辦公室服務。請檢查 VPS 與 SSH 連線後重試。"
            self.connecting = false
            if self.ownsTunnel { self.tunnel.stop(); self.ownsTunnel = false }
        }
    }

    private func monitor(_ token: UUID) async {
        while !Task.isCancelled && generation == token {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            let available = await healthy()
            guard generation == token, !Task.isCancelled else { return }
            ready = available
            message = available ? "已驗證 VPS 辦公室連線" : "連線中斷；已交辦工作仍在 VPS，草稿留在面板。"
        }
    }

    func disconnect() {
        generation = UUID(); checkTask?.cancel(); checkTask = nil
        if ownsTunnel { tunnel.stop(); ownsTunnel = false }
        ready = false; connecting = false
        message = "面板已離線；已交辦工作仍保存在 VPS。"
        // Keep the web view alive so an unsent draft is not discarded.
    }
}

struct OfficePanelView: View {
    @ObservedObject var model: OfficePanelModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("貓咪辦公室").font(.headline)
                    Text(model.message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.pageURL == nil {
                    TextField("既有 SSH 別名", text: $model.hostAlias).frame(width: 140)
                        .disabled(model.connecting)
                }
                Button(model.connecting ? "確認中…" : "連線／重連") { model.connect() }.disabled(model.connecting)
                Button("離線") { model.disconnect() }.disabled(!model.ownsTunnel && !model.connecting)
            }.padding(14)
            Divider()
            if let url = model.pageURL {
                OfficeWebView(url: url)
            } else {
                VStack(spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 120, height: 120)
                    Text("讓貓咪接住工作，也記下生活。").font(.title2)
                    Text("連線後可交辦任務、保存交接、記錄生活。\n外部 Agent 的帳號狀態會在面板顯示。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Text("獨立預覽 · 使用已設定的 SSH 連線 · 關閉面板後 VPS 工作繼續")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct OfficeWebView: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        private var destinations: [ObjectIdentifier: URL] = [:]
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.scheme == "http", url.host == "127.0.0.1", url.port == 18421 {
                decisionHandler(action.shouldPerformDownload ? .download : .allow)
            } else {
                if action.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            }
        }
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }
        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "貓咪辦公室-紀錄.md"
            panel.allowedContentTypes = [.plainText]
            panel.begin { result in
                guard result == .OK, let url = panel.url else { completionHandler(nil); return }
                self.destinations[ObjectIdentifier(download)] = url
                completionHandler(url)
            }
        }
        func downloadDidFinish(_ download: WKDownload) { destinations.removeValue(forKey: ObjectIdentifier(download)) }
        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            destinations.removeValue(forKey: ObjectIdentifier(download))
        }
    }
}
