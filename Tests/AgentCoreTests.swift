import Foundation

private final class FakeTransport: AgentTransport {
    var onEvent: ((AgentEvent) -> Void)?
    var isDemonstration = true
    var starts = 0
    var cancels = 0
    var startError: Error?
    var duringStart: (() -> Void)?
    var duringCancel: (() -> Void)?
    func start(_ task: AgentTask) throws {
        starts += 1
        if let startError { throw startError }
        duringStart?()
    }
    func cancel(taskID: UUID) { cancels += 1; duringCancel?() }
}

private struct FakeAdapter: ProviderAdapter {
    let provider: AgentProvider = .codex
    let transport: FakeTransport
    func makeTransport() -> AgentTransport { transport }
}

@main
enum AgentCoreTests {
    static func main() throws {
        var scenarios = 0
        func check(_ name: String, _ test: () throws -> Void) rethrows {
            try test(); scenarios += 1
        }
        func fixture() throws -> (AgentTaskCoordinator, FakeTransport, UUID) {
            let c = AgentTaskCoordinator(), t = FakeTransport()
            let id = try c.submit(prompt: "  查詢三個網頁\n", using: FakeAdapter(transport: t))
            return (c, t, id)
        }
        try check("task and event wire round trip") {
            let (c, _, id) = try fixture()
            precondition(c.task?.prompt == "查詢三個網頁")
            let data = try JSONEncoder().encode(c.task!)
            let decodedTask = try JSONDecoder().decode(AgentTask.self, from: data)
            precondition(decodedTask == c.task)
            let event = AgentEvent(taskID: id, sequence: 0, kind: .progress, message: "示範", progress: 0.2)
            let wire = try JSONEncoder().encode(event)
            let decodedEvent = try JSONDecoder().decode(AgentEvent.self, from: wire)
            precondition(decodedEvent == event)
        }
        check("reject empty and overlong prompt") {
            for prompt in [" \n ", String(repeating: "字", count: 5_001)] {
                let c = AgentTaskCoordinator(), t = FakeTransport()
                do { try c.submit(prompt: prompt, using: FakeAdapter(transport: t)); preconditionFailure() }
                catch { precondition(t.starts == 0 && c.task == nil) }
            }
        }
        try check("duplicate submission") {
            let (c, t, id) = try fixture()
            do { try c.submit(prompt: "第二件", using: FakeAdapter(transport: t)); preconditionFailure() }
            catch { precondition(t.starts == 1 && c.task?.id == id) }
        }
        try check("normal progress and completion") {
            let (c, t, id) = try fixture()
            t.onEvent?(AgentEvent(taskID: id, sequence: 0, kind: .progress, message: "整理", progress: 0.5))
            t.onEvent?(AgentEvent(taskID: id, sequence: 1, kind: .completed, message: "示範完成", result: "示範結果"))
            precondition(c.task?.status == .completed && c.task?.progress == 1 && c.task?.result == "示範結果")
        }
        try check("late completion after cancel, including synchronous callback") {
            let (c, t, id) = try fixture()
            let late = t.onEvent!
            t.duringCancel = { late(AgentEvent(taskID: id, sequence: 1, kind: .completed, message: "late", result: "bad")) }
            c.cancel(); c.cancel()
            late(AgentEvent(taskID: id, sequence: 2, kind: .completed, message: "late", result: "bad"))
            precondition(c.task?.status == .cancelled && c.task?.result == nil && t.cancels == 1)
        }
        try check("old run cannot corrupt next task") {
            let (c, t, oldID) = try fixture()
            let late = t.onEvent!
            c.cancel()
            let next = FakeTransport()
            let newID = try c.submit(prompt: "新任務", using: FakeAdapter(transport: next))
            late(AgentEvent(taskID: oldID, sequence: 100, kind: .failed, message: "bad"))
            precondition(c.task?.id == newID && c.isRunning && c.events.isEmpty)
        }
        try check("wrong task, duplicate and out-of-order events") {
            let (c, t, id) = try fixture()
            t.onEvent?(AgentEvent(taskID: UUID(), sequence: 100, kind: .completed, message: "bad", result: "bad"))
            t.onEvent?(AgentEvent(taskID: id, sequence: 2, kind: .progress, message: "有效", progress: 0.4))
            t.onEvent?(AgentEvent(taskID: id, sequence: 1, kind: .completed, message: "old", result: "old"))
            precondition(c.events.count == 1 && c.isRunning)
        }
        try check("terminal status is immutable") {
            let (c, t, id) = try fixture()
            let late = t.onEvent!
            late(AgentEvent(taskID: id, sequence: 0, kind: .completed, message: "ok", result: "demo"))
            late(AgentEvent(taskID: id, sequence: 1, kind: .failed, message: "bad")); c.cancel()
            precondition(c.task?.status == .completed)
        }
        try check("startup failure") {
            let c = AgentTaskCoordinator(), t = FakeTransport()
            t.startError = AgentSubmissionError.remoteNotVerified
            try c.submit(prompt: "示範", using: FakeAdapter(transport: t))
            precondition(c.task?.status == .failed && c.task?.result == nil)
        }
        try check("disconnect never retries or completes") {
            let (c, t, id) = try fixture()
            t.onEvent?(AgentEvent(taskID: id, sequence: 0, kind: .disconnected, message: "示範斷線"))
            precondition(c.task?.status == .failed && t.starts == 1 && c.task?.result == nil)
        }
        try check("invalid progress and unsupported version") {
            for value in [Double.nan, -1, 1, 2] {
                let (c, t, id) = try fixture()
                t.onEvent?(AgentEvent(taskID: id, sequence: 0, kind: .progress, message: "bad", progress: value))
                precondition(c.task?.status == .failed)
            }
            let (c, t, id) = try fixture()
            t.onEvent?(AgentEvent(protocolVersion: 999, taskID: id, sequence: 0, kind: .completed, message: "bad", result: "bad"))
            precondition(c.task?.status == .failed)
        }
        try check("missing result cannot complete") {
            let (c, t, id) = try fixture()
            t.onEvent?(AgentEvent(taskID: id, sequence: 0, kind: .completed, message: "bad", result: " \n"))
            precondition(c.task?.status == .failed)
        }
        try check("live execution stays gated") {
            let c = AgentTaskCoordinator(), t = FakeTransport(); t.isDemonstration = false
            do { try c.submit(prompt: "live", using: FakeAdapter(transport: t)); preconditionFailure() }
            catch { precondition(t.starts == 0 && c.task == nil) }
            let (other, demo, id) = try fixture()
            demo.onEvent?(AgentEvent(taskID: id, sequence: 0, kind: .completed, message: "bad", result: "live", isDemonstration: false))
            precondition(other.task?.status == .failed)
        }
        try check("cancel during submission notification prevents launch") {
            let c = AgentTaskCoordinator(), t = FakeTransport()
            c.onChange = { if c.isRunning { c.cancel() } }
            try c.submit(prompt: "示範", using: FakeAdapter(transport: t))
            precondition(t.starts == 0 && c.task?.status == .cancelled)
        }
        try check("demo completes without external services") {
            var scheduled: [DispatchWorkItem] = []
            let demo = DemoAgentTransport(schedule: { _, item in scheduled.append(item) })
            let id = UUID()
            var received: [AgentEvent] = []
            demo.onEvent = { received.append($0) }
            try demo.start(AgentTask(id: id, prompt: "測試", provider: .gemini, createdAt: Date()))
            scheduled.forEach { $0.perform() }
            precondition(received.count == 5 && received.last?.kind == .completed)
            precondition(received.allSatisfy(\.isDemonstration))
            demo.cancel(taskID: id)
        }
        try check("demo cancellation drops scheduled events") {
            var scheduled: [DispatchWorkItem] = []
            let demo = DemoAgentTransport(schedule: { _, item in scheduled.append(item) })
            let task = AgentTask(id: UUID(), prompt: "測試", provider: .claude, createdAt: Date())
            var received = 0; demo.onEvent = { _ in received += 1 }
            try demo.start(task); demo.cancel(taskID: task.id)
            scheduled.forEach { $0.perform() }
            precondition(received == 0)
        }
        print("Agent core tests passed (\(scenarios) scenarios)")
    }
}
