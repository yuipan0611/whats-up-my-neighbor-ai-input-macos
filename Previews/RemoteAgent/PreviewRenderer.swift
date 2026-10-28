import AppKit
import SwiftUI

/// Renders only this app's view tree. Never records the desktop or requests TCC.
enum PreviewRenderer {
    private final class FixtureTransport: AgentTransport {
        var onEvent: ((AgentEvent) -> Void)?
        let isDemonstration = true
        var taskID: UUID?
        func start(_ task: AgentTask) throws { taskID = task.id }
        func cancel(taskID: UUID) {}
        func emit(_ kind: AgentEvent.Kind, sequence: Int, message: String, progress: Double? = nil, result: String? = nil) {
            onEvent?(AgentEvent(taskID: taskID!, sequence: sequence, kind: kind,
                message: message, progress: progress, result: result))
        }
    }
    private struct FixtureAdapter: ProviderAdapter {
        let provider: AgentProvider
        let transport: FixtureTransport
        func makeTransport() -> AgentTransport { transport }
    }

    private final class FixtureSSHProcess: SSHProcessRunning {
        var onExit: ((Int32) -> Void)?
        func start(arguments: [String]) throws {}
        func stop() {}
    }
    private final class FixtureProbe: VNCServerProbing {
        let reachable: Bool
        init(reachable: Bool) { self.reachable = reachable }
        func probe(port: Int, timeout: TimeInterval, completion: @escaping (Bool) -> Void) -> () -> Void {
            completion(reachable)
            return {}
        }
    }
    private final class FixtureLauncher: RemoteViewerLaunching {
        func open(_ url: URL, completion: @escaping (Bool) -> Void) { completion(true) }
    }

    private final class FixtureClock {
        private(set) var now = Date(timeIntervalSince1970: 0)
        func schedule(_ delay: TimeInterval, _ item: DispatchWorkItem) {
            now = now.addingTimeInterval(delay)
            item.perform()
        }
    }

    private static func handoffFixture(reachable: Bool) -> RemoteDesktopHandoffModel {
        let clock = FixtureClock()
        let controller = RemoteDesktopHandoffController(
            makeTunnel: { SSHTunnelController(makeProcess: { FixtureSSHProcess() }) },
            prober: FixtureProbe(reachable: reachable), launcher: FixtureLauncher(),
            isLocalPortFree: { _ in true },
            schedule: clock.schedule,
            now: { clock.now })
        return RemoteDesktopHandoffModel(controller: controller)
    }

    static func render(to output: URL) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let transport = FixtureTransport()
        let idleHandoff = handoffFixture(reachable: true)
        let model = RemoteAgentPreviewModel(preferences: PreviewPreferencesStore(directory: output.appendingPathComponent("render-preferences")),
            adapterFactory: { FixtureAdapter(provider: $0, transport: transport) })
        model.useExample()
        try capture(model, handoff: idleHandoff, name: "ready", output: output)
        model.startDemo()
        transport.emit(.progress, sequence: 0, message: "已接收任務，開始本機示範。", progress: 0.15)
        transport.emit(.progress, sequence: 1, message: "模擬查詢網頁；沒有實際開啟或讀取網站。", progress: 0.38)
        try capture(model, handoff: idleHandoff, name: "running", output: output)
        model.cancel()
        try capture(model, handoff: idleHandoff, name: "cancelled", output: output)
        model.startDemo()
        transport.emit(.failed, sequence: 0, message: "示範連線中斷，請重新執行示範。")
        try capture(model, handoff: idleHandoff, name: "failed", output: output)
        model.startDemo()
        transport.emit(.completed, sequence: 0, message: "示範流程完成，未執行遠端任務。",
            result: "本次只驗證任務流程，沒有查詢網頁、呼叫 AI 或寫入備忘錄。\n\n接上並驗證 Linux VPS 後，這裡會呈現重點、來源與儲存位置。")
        try capture(model, handoff: idleHandoff, name: "completed", output: output)
        try capture(model, handoff: idleHandoff, name: "compact-dark", output: output, size: NSSize(width: 760, height: 680), dark: true)
        let opened = handoffFixture(reachable: true)
        opened.hostAlias = "neighbor-vps"
        opened.start()
        try capture(model, handoff: opened, name: "handoff-opened", output: output)
        let failed = handoffFixture(reachable: false)
        failed.targetKind = .macSecondUser
        failed.start()
        try capture(model, handoff: failed, name: "handoff-failed-compact-dark", output: output,
                    size: NSSize(width: 760, height: 680), dark: true)
        print("Rendered eight preview states: \(output.path)")
    }

    private static func capture(_ model: RemoteAgentPreviewModel, handoff: RemoteDesktopHandoffModel,
                                name: String, output: URL,
                                size: NSSize = NSSize(width: 980, height: 780), dark: Bool = false) throws {
        let view = NSHostingView(rootView: RemoteAgentView(model: model, handoff: handoff))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: output.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }
}
