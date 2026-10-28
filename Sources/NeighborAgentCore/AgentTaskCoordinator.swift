import Foundation

/// Independent of dictation, clipboard, Keychain, AppKit and all production state.
final class AgentTaskCoordinator {
    private(set) var task: AgentTask?
    private(set) var events: [AgentEvent] = []
    var onChange: (() -> Void)?
    private var transport: AgentTransport?
    private var generation: UUID?
    private var lastSequence = -1

    var isRunning: Bool { task?.status == .running }

    @discardableResult
    func submit(prompt: String, using adapter: ProviderAdapter) throws -> UUID {
        precondition(Thread.isMainThread)
        guard !isRunning else { throw AgentSubmissionError.busy }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw AgentSubmissionError.emptyPrompt }
        guard prompt.count <= 5_000 else { throw AgentSubmissionError.promptTooLong }
        let next = adapter.makeTransport()
        // Live task execution is deliberately gated until the remote protocol
        // and each provider are verified. A tunnel alone cannot open this gate.
        guard next.isDemonstration else { throw AgentSubmissionError.remoteNotVerified }
        let current = AgentTask(id: UUID(), prompt: prompt, provider: adapter.provider, createdAt: Date())
        let token = UUID()
        generation = token
        task = current
        events = []
        lastSequence = -1
        transport = next
        next.onEvent = { [weak self] event in self?.receive(event, generation: token) }
        onChange?()
        guard generation == token, isRunning else { return current.id }
        do {
            try next.start(current)
        } catch {
            if generation == token, isRunning {
                finish(.failed, failure: "無法啟動示範：\(error.localizedDescription)")
            }
        }
        return current.id
    }

    func cancel() {
        precondition(Thread.isMainThread)
        guard isRunning else { return }
        finish(.cancelled)
        // finish invalidates the event generation BEFORE cancel can callback.
    }

    private func receive(_ event: AgentEvent, generation token: UUID) {
        precondition(Thread.isMainThread)
        guard generation == token, isRunning, event.taskID == task?.id else { return }
        guard event.protocolVersion == AgentEvent.currentVersion, event.isDemonstration else {
            finish(.failed, failure: "收到不支援的事件，已停止示範。")
            return
        }
        guard event.sequence > lastSequence else { return }
        guard event.message.count <= 4_000, (event.result?.count ?? 0) <= 40_000 else {
            finish(.failed, failure: "收到過大的事件，已停止示範。")
            return
        }
        if event.kind == .progress {
            guard let progress = event.progress, progress.isFinite,
                  progress >= (task?.progress ?? 0), progress >= 0, progress < 1 else {
                finish(.failed, failure: "進度資料無效，已停止示範。")
                return
            }
            task?.progress = progress
        }
        if event.kind == .completed {
            guard let result = event.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                finish(.failed, failure: "沒有收到示範結果，不能標示完成。")
                return
            }
            task?.result = result
            task?.progress = 1
        }
        lastSequence = event.sequence
        events.append(event)
        if events.count > 200 { events.removeFirst(events.count - 200) }
        switch event.kind {
        case .progress: onChange?()
        case .completed: finish(.completed)
        case .failed: finish(.failed, failure: event.message)
        case .disconnected: finish(.failed, failure: "連線中斷，任務未重試。\(event.message)")
        }
    }

    private func finish(_ status: AgentTaskStatus, failure: String? = nil) {
        let previous = transport
        let taskID = task?.id
        generation = nil
        transport = nil
        previous?.onEvent = nil
        task?.status = status
        task?.failure = failure
        if let taskID { previous?.cancel(taskID: taskID) }
        onChange?()
    }
}
