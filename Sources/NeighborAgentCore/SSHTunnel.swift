import Foundation
import Darwin

struct SSHTunnelConfiguration: Equatable {
    let hostAlias: String
    var localPort: Int = 18421
    var remotePort: Int = 8421

    func arguments() throws -> [String] {
        // An existing ssh_config alias, never a shell command or free-form flags.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !hostAlias.isEmpty, hostAlias.utf8.count <= 128,
              hostAlias.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              hostAlias.first != "-", hostAlias.first != "." else { throw SSHTunnelError.invalidAlias }
        guard (1024...65535).contains(localPort), (1024...65535).contains(remotePort) else {
            throw SSHTunnelError.invalidPort
        }
        return ["-N", "-T", "-n", "-a", "-x",
            "-o", "BatchMode=yes", "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no", "-o", "StrictHostKeyChecking=yes",
            "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2", "-o", "ControlMaster=no",
            "-o", "ControlPath=none", "-o", "ControlPersist=no",
            "-o", "ForkAfterAuthentication=no", "-o", "UpdateHostKeys=no",
            "-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none",
            "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
            "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)", "--", hostAlias]
    }
}

enum SSHTunnelError: LocalizedError {
    case invalidAlias, invalidPort, alreadyRunning
    var errorDescription: String? {
        switch self {
        case .invalidAlias: return "請使用既有 SSH 主機別名，只能包含英數字、底線、連字號與句點。"
        case .invalidPort: return "通道連接埠需介於 1024 與 65535。"
        case .alreadyRunning: return "SSH 通道已在啟動或執行中，請先停止。"
        }
    }
}

enum SSHTunnelState: Equatable {
    case idle, starting, processRunning, stopped, failed(String)
    var isActive: Bool { self == .starting || self == .processRunning }
}

protocol SSHProcessRunning: AnyObject {
    var onExit: ((Int32) -> Void)? { get set }
    func start(arguments: [String]) throws
    func stop()
}

/// Runs ONLY the system SSH binary. No shell, password prompts, remote command,
/// daemonization, agent forwarding, global process termination or raw log output.
final class SystemSSHProcess: SSHProcessRunning {
    var onExit: ((Int32) -> Void)?
    private var process: Process?

    func start(arguments: [String]) throws {
        precondition(Thread.isMainThread)
        guard process == nil else { throw SSHTunnelError.alreadyRunning }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        // Avoid unbounded pipes, and never persist server/user/authentication text.
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            let code = ended.terminationStatus
            DispatchQueue.main.async { self?.onExit?(code) }
        }
        self.process = process
        do { try process.run() }
        catch { self.process = nil; throw error }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    deinit { if let process, process.isRunning { process.terminate() } }
}

/// A running SSH process is NOT evidence of an authenticated host, a ready
/// forward, a reachable remote service, an AI login, or a completed task.
final class SSHTunnelController {
    private(set) var state: SSHTunnelState = .idle
    var onStateChange: ((SSHTunnelState) -> Void)?
    private let makeProcess: () -> SSHProcessRunning
    private var runner: SSHProcessRunning?
    private var generation: UUID?

    init(makeProcess: @escaping () -> SSHProcessRunning = { SystemSSHProcess() }) {
        self.makeProcess = makeProcess
    }

    func start(configuration: SSHTunnelConfiguration) throws {
        precondition(Thread.isMainThread)
        guard !state.isActive else { throw SSHTunnelError.alreadyRunning }
        let arguments = try configuration.arguments()
        let token = UUID(), next = makeProcess()
        generation = token
        runner = next
        next.onExit = { [weak self] code in self?.exited(code, generation: token) }
        state = .starting
        onStateChange?(state)
        guard generation == token else { return }
        do {
            try next.start(arguments: arguments)
            guard generation == token else { return }
            state = .processRunning
            onStateChange?(state)
        } catch {
            guard generation == token else { return }
            end(.failed("無法啟動系統 SSH。請確認工具與連線設定後再試。"))
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        guard state.isActive else { return }
        end(.stopped)
    }

    private func exited(_ code: Int32, generation token: UUID) {
        precondition(Thread.isMainThread)
        guard generation == token else { return }
        end(.failed("SSH 程序已結束（狀態 \(code)）。遠端服務未驗證；請檢查登入、主機指紋及連接埠後重試。"))
    }

    private func end(_ nextState: SSHTunnelState) {
        let previous = runner
        generation = nil
        runner = nil
        previous?.onExit = nil
        state = nextState
        previous?.stop()
        onStateChange?(state)
    }

    deinit { runner?.onExit = nil; runner?.stop() }
}
