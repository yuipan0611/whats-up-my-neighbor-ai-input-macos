import Foundation
import Combine

enum RemoteDesktopTargetKind: String, CaseIterable {
    case linuxVPS, macSecondUser

    var displayName: String {
        switch self {
        case .linuxVPS: return "Linux VPS"
        case .macSecondUser: return "本機第二使用者"
        }
    }
}

final class RemoteDesktopHandoffModel: ObservableObject {
    @Published var targetKind: RemoteDesktopTargetKind = .linuxVPS
    @Published var hostAlias = ""
    @Published private(set) var state: RemoteDesktopHandoffState = .idle
    @Published private(set) var errorMessage: String?
    let controller: RemoteDesktopHandoffController

    init(controller: RemoteDesktopHandoffController = RemoteDesktopHandoffController()) {
        self.controller = controller
        controller.onStateChange = { [weak self] in self?.state = $0 }
    }

    var isActive: Bool { state.isActive }
    var isWorking: Bool { state == .openingTunnel || state == .probing || state == .openingViewer }
    var canStop: Bool { state == .probing || state == .viewerOpened }

    var canStart: Bool {
        guard !isActive else { return false }
        return targetKind == .macSecondUser || !trimmedAlias.isEmpty
    }

    var statusText: String? {
        guard errorMessage == nil else { return nil }
        switch state {
        case .idle, .failed: return nil
        case .openingTunnel: return "正在建立 SSH 通道…"
        case .probing: return "正在確認 VNC 伺服器…"
        case .openingViewer: return "正在開啟螢幕共享…"
        case .viewerOpened: return "已開啟「螢幕共享」。VNC 密碼請在螢幕共享視窗輸入；本 App 不保存密碼。"
        case .stopped:
            if case .linuxVPS = controller.target { return "已結束接手，SSH 通道已關閉。" }
            return "已結束接手。螢幕共享視窗若仍開著，請自行關閉。"
        }
    }

    var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return errorMessage
    }

    func start() {
        guard canStart else { return }
        errorMessage = nil
        let target: RemoteDesktopTarget = targetKind == .linuxVPS
            ? .linuxVPS(hostAlias: trimmedAlias) : .macSecondUser
        do { try controller.start(target) }
        catch { errorMessage = error.localizedDescription }
    }

    func stop() { controller.stop() }

    private var trimmedAlias: String { hostAlias.trimmingCharacters(in: .whitespacesAndNewlines) }
}
