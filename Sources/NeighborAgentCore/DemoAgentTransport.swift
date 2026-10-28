import Foundation

/// Fixed local fixtures only: no model SDK, URLSession, Process or desktop API.
final class DemoAgentTransport: AgentTransport {
    var onEvent: ((AgentEvent) -> Void)?
    let isDemonstration = true
    private var activeTaskID: UUID?
    private var pending: [DispatchWorkItem] = []
    private let schedule: (Double, DispatchWorkItem) -> Void

    init(schedule: @escaping (Double, DispatchWorkItem) -> Void = { delay, item in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }) { self.schedule = schedule }

    func start(_ task: AgentTask) throws {
        precondition(Thread.isMainThread)
        guard activeTaskID == nil else { throw AgentSubmissionError.busy }
        activeTaskID = task.id
        let steps: [(Double, Double, String)] = [
            (0.35, 0.15, "已接收任務，開始本機示範。"),
            (1.3, 0.38, "模擬查詢網頁；沒有實際開啟或讀取網站。"),
            (2.5, 0.65, "模擬整理重點；以下內容為固定示範資料。"),
            (3.7, 0.85, "模擬準備儲存；沒有建立檔案或備忘錄。")
        ]
        for (index, step) in steps.enumerated() {
            enqueue(after: step.0, event: AgentEvent(taskID: task.id, sequence: index,
                kind: .progress, message: step.2, progress: step.1))
        }
        enqueue(after: 5, event: AgentEvent(taskID: task.id, sequence: 4,
            kind: .completed, message: "示範流程完成，未執行遠端任務。",
            result: "示範結果\n\n這裡會呈現分身整理的重點、來源與儲存位置。\n\n本次只驗證任務面板與進度流程，沒有查詢網頁、呼叫 AI、操作桌面或寫入備忘錄。\n\n接上並驗證 Linux VPS 後，才能在此取得真實執行結果。"))
    }

    private func enqueue(after delay: Double, event: AgentEvent) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.activeTaskID == event.taskID else { return }
            self.onEvent?(event)
        }
        pending.append(item)
        schedule(delay, item)
    }

    func cancel(taskID: UUID) {
        precondition(Thread.isMainThread)
        guard activeTaskID == taskID else { return }
        activeTaskID = nil
        pending.forEach { $0.cancel() }
        pending.removeAll()
    }
}
