import Foundation

enum AgentProvider: String, CaseIterable, Codable {
    case codex, gemini, claude

    var displayName: String {
        switch self {
        case .codex: return "GPT / Codex"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        }
    }

    var availabilityDescription: String { "待遠端驗證" }
}

enum AgentTaskStatus: String, Codable {
    case running, completed, cancelled, failed
    var isTerminal: Bool { self != .running }
}

struct AgentTask: Equatable, Codable {
    let id: UUID
    let prompt: String
    let provider: AgentProvider
    let createdAt: Date
    var status: AgentTaskStatus = .running
    var progress: Double = 0
    var result: String?
    var failure: String?
}

struct AgentEvent: Equatable, Codable {
    static let currentVersion = 1
    enum Kind: String, Codable { case progress, completed, failed, disconnected }

    var protocolVersion: Int = currentVersion
    let taskID: UUID
    let sequence: Int
    let kind: Kind
    let message: String
    var progress: Double?
    var result: String?
    var isDemonstration: Bool = true
}

enum AgentSubmissionError: LocalizedError {
    case busy, emptyPrompt, promptTooLong, remoteNotVerified
    var errorDescription: String? {
        switch self {
        case .busy: return "已有示範正在執行，請先取消或等待完成。"
        case .emptyPrompt: return "請先輸入要交辦的事情。"
        case .promptTooLong: return "任務內容最多 5,000 字，請縮短後再試。"
        case .remoteNotVerified: return "遠端服務尚未驗證，目前只能執行本機示範。"
        }
    }
}

/// Calls and events are serialized on the main thread. A transport must never
/// interpret a successful local process launch as successful task completion.
protocol AgentTransport: AnyObject {
    var onEvent: ((AgentEvent) -> Void)? { get set }
    var isDemonstration: Bool { get }
    func start(_ task: AgentTask) throws
    func cancel(taskID: UUID)
}

protocol ProviderAdapter {
    var provider: AgentProvider { get }
    func makeTransport() -> AgentTransport
}

struct DemoProviderAdapter: ProviderAdapter {
    let provider: AgentProvider
    func makeTransport() -> AgentTransport { DemoAgentTransport() }
}
