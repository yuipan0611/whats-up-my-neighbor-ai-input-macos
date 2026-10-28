import Foundation
import Network
import Darwin

enum RemoteDesktopTarget: Equatable {
    case linuxVPS(hostAlias: String)
    case macSecondUser

    static let vpsLocalPort = 15901
    static let remoteVNCPort = 5901
    static let secondUserPort = 5901

    var probePort: Int {
        switch self {
        case .linuxVPS: return Self.vpsLocalPort
        case .macSecondUser: return Self.secondUserPort
        }
    }

    var viewerURL: URL { URL(string: "vnc://127.0.0.1:\(probePort)")! }

    var tunnelConfiguration: SSHTunnelConfiguration? {
        guard case .linuxVPS(let alias) = self else { return nil }
        return SSHTunnelConfiguration(hostAlias: alias, localPort: Self.vpsLocalPort, remotePort: Self.remoteVNCPort)
    }

    static func isAllowedViewerURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "vnc" && parts.host == "127.0.0.1"
            && [vpsLocalPort, secondUserPort].contains(parts.port ?? -1)
            && parts.user == nil && parts.password == nil
            && parts.path.isEmpty && parts.query == nil && parts.fragment == nil
    }
}

enum SystemLocalPort {
    static func isFree(port: Int) -> Bool {
        guard (1024...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            return false
        }
        return errno == ECONNREFUSED
    }
}

extension SSHTunnelConfiguration {
    func validate() throws { _ = try arguments() }
}

/// The 12-byte ProtocolVersion message every RFB (VNC) server sends first: "RFB xxx.yyy\n".
enum RFBBanner {
    static let length = 12

    static func isValid(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard bytes.count == length, Array(bytes[0...3]) == Array("RFB ".utf8),
              bytes[7] == UInt8(ascii: "."), bytes[11] == UInt8(ascii: "\n") else { return false }
        return [4, 5, 6, 8, 9, 10].allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[$0]) }
    }
}

protocol VNCServerProbing: AnyObject {
    func probe(port: Int, timeout: TimeInterval, completion: @escaping (Bool) -> Void) -> () -> Void
}

final class SystemVNCProbe: VNCServerProbing {
    private let queue = DispatchQueue(label: "tw.panh.neighbor.vnc-probe")

    private enum Outcome {
        case answered(Bool)
        case cancelled
    }

    private final class Attempt {
        let connection: NWConnection
        var finished = false
        init(connection: NWConnection) { self.connection = connection }
    }

    func probe(port: Int, timeout: TimeInterval, completion: @escaping (Bool) -> Void) -> () -> Void {
        guard (1024...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            DispatchQueue.main.async { completion(false) }
            return {}
        }
        let queue = self.queue
        let attempt = Attempt(connection: NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp))
        let finish: (Outcome) -> Void = { outcome in
            dispatchPrecondition(condition: .onQueue(queue))
            guard !attempt.finished else { return }
            attempt.finished = true
            attempt.connection.stateUpdateHandler = nil
            attempt.connection.cancel()
            if case .answered(let result) = outcome {
                DispatchQueue.main.async { completion(result) }
            }
        }
        attempt.connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                attempt.connection.receive(minimumIncompleteLength: RFBBanner.length,
                                           maximumLength: RFBBanner.length) { data, _, _, error in
                    finish(.answered(error == nil && data.map(RFBBanner.isValid) == true))
                }
            // Refused connections surface as .waiting; do not let NWConnection retry.
            case .waiting, .failed, .cancelled:
                finish(.answered(false))
            default:
                break
            }
        }
        attempt.connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(.answered(false)) }
        return { queue.async { finish(.cancelled) } }
    }
}

protocol RemoteViewerLaunching: AnyObject {
    func open(_ url: URL, completion: @escaping (Bool) -> Void)
}

final class ScreenSharingLauncher: RemoteViewerLaunching {
    static let bundleIdentifier = "com.apple.ScreenSharing"

    static func arguments(for url: URL) -> [String]? {
        guard RemoteDesktopTarget.isAllowedViewerURL(url) else { return nil }
        return ["-b", bundleIdentifier, url.absoluteString]
    }

    func open(_ url: URL, completion: @escaping (Bool) -> Void) {
        guard let arguments = Self.arguments(for: url) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { ended in
            let succeeded = ended.terminationStatus == 0
            DispatchQueue.main.async { completion(succeeded) }
        }
        do { try process.run() }
        catch { DispatchQueue.main.async { completion(false) } }
    }
}

enum RemoteDesktopHandoffState: Equatable {
    case idle, openingTunnel, probing, openingViewer, viewerOpened, stopped, failed(String)

    var isActive: Bool {
        switch self {
        case .openingTunnel, .probing, .openingViewer, .viewerOpened: return true
        case .idle, .stopped, .failed: return false
        }
    }
}

enum RemoteDesktopHandoffError: LocalizedError {
    case alreadyActive
    var errorDescription: String? { "接手控制已在進行中，請先結束。" }
}

final class RemoteDesktopHandoffController {
    static let probeDeadline: TimeInterval = 10
    static let probeInterval: TimeInterval = 0.5
    static let probeAttemptTimeout: TimeInterval = 2

    static let tunnelFailedMessage = "SSH 通道沒有建立成功或已結束。請檢查 SSH 別名、金鑰登入與主機指紋後，再按一次「接手控制」。"
    static let tunnelLostMessage = "SSH 通道已中斷，螢幕共享畫面會停止。請確認連線後再按一次「接手控制」。"
    static let viewerFailedMessage = "無法開啟「螢幕共享」。請確認系統內建 App 可用後再試。"
    static let portInUseMessage = "本機 127.0.0.1:15901 已被其他程式佔用，可能是先前沒有結束的 SSH 通道。請用「lsof -nP -iTCP:15901」找出並結束它，再按一次「接手控制」。"
    static func probeTimeoutMessage(for target: RemoteDesktopTarget) -> String {
        let lead = "找不到 VNC 伺服器：127.0.0.1:\(target.probePort) 在 10 秒內沒有回應 VNC 訊號。"
        switch target {
        case .linuxVPS: return lead + "請確認遠端已啟動 VNC 伺服器，並檢查 SSH 別名與主機指紋。"
        case .macSecondUser: return lead + "請確認第二使用者已登入，且 VNC 伺服器已啟動並只允許本機連線。"
        }
    }

    private(set) var state: RemoteDesktopHandoffState = .idle
    private(set) var target: RemoteDesktopTarget?
    var onStateChange: ((RemoteDesktopHandoffState) -> Void)?

    private let makeTunnel: () -> SSHTunnelController
    private let prober: VNCServerProbing
    private let launcher: RemoteViewerLaunching
    private let isLocalPortFree: (Int) -> Bool
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    private let now: () -> Date
    private var tunnel: SSHTunnelController?
    private var generation: UUID?
    private var cancelProbe: (() -> Void)?
    private var pendingRetry: DispatchWorkItem?

    init(makeTunnel: @escaping () -> SSHTunnelController = { SSHTunnelController() },
         prober: VNCServerProbing = SystemVNCProbe(),
         launcher: RemoteViewerLaunching = ScreenSharingLauncher(),
         isLocalPortFree: @escaping (Int) -> Bool = SystemLocalPort.isFree(port:),
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, item in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
         },
         now: @escaping () -> Date = Date.init) {
        self.makeTunnel = makeTunnel
        self.prober = prober
        self.launcher = launcher
        self.isLocalPortFree = isLocalPortFree
        self.schedule = schedule
        self.now = now
    }

    func start(_ target: RemoteDesktopTarget) throws {
        precondition(Thread.isMainThread)
        guard !state.isActive else { throw RemoteDesktopHandoffError.alreadyActive }
        let configuration = target.tunnelConfiguration
        if let configuration { try configuration.validate() }
        if case .linuxVPS = target {
            guard isLocalPortFree(RemoteDesktopTarget.vpsLocalPort) else {
                self.target = target
                transition(.failed(Self.portInUseMessage))
                return
            }
        }
        let token = UUID()
        generation = token
        self.target = target
        if let configuration {
            let next = makeTunnel()
            tunnel = next
            next.onStateChange = { [weak self] tunnelState in self?.tunnelChanged(tunnelState, generation: token) }
            transition(.openingTunnel)
            guard generation == token else { return }
            do { try next.start(configuration: configuration) }
            catch {
                if generation == token { end(.failed(Self.tunnelFailedMessage)) }
                return
            }
            guard generation == token, next.state == .processRunning else { return }
        }
        transition(.probing)
        attemptProbe(generation: token, deadline: now().addingTimeInterval(Self.probeDeadline))
    }

    func stop() {
        precondition(Thread.isMainThread)
        guard state.isActive else { return }
        end(.stopped)
    }

    private func attemptProbe(generation token: UUID, deadline: Date) {
        guard generation == token, state == .probing, let target else { return }
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else { end(.failed(Self.probeTimeoutMessage(for: target))); return }
        pendingRetry = nil
        cancelProbe = prober.probe(port: target.probePort, timeout: min(Self.probeAttemptTimeout, remaining)) { [weak self] reachable in
            self?.probeFinished(reachable, generation: token, deadline: deadline)
        }
    }

    private func probeFinished(_ reachable: Bool, generation token: UUID, deadline: Date) {
        precondition(Thread.isMainThread)
        guard generation == token, state == .probing, let target else { return }
        cancelProbe = nil
        if reachable {
            openViewer(target.viewerURL, generation: token)
            return
        }
        guard now().addingTimeInterval(Self.probeInterval) < deadline else {
            end(.failed(Self.probeTimeoutMessage(for: target)))
            return
        }
        let retry = DispatchWorkItem { [weak self] in self?.attemptProbe(generation: token, deadline: deadline) }
        pendingRetry = retry
        schedule(Self.probeInterval, retry)
    }

    private func openViewer(_ url: URL, generation token: UUID) {
        transition(.openingViewer)
        launcher.open(url) { [weak self] opened in
            precondition(Thread.isMainThread)
            guard let self, self.generation == token, self.state == .openingViewer else { return }
            if opened { self.transition(.viewerOpened) } else { self.end(.failed(Self.viewerFailedMessage)) }
        }
    }

    private func tunnelChanged(_ tunnelState: SSHTunnelState, generation token: UUID) {
        guard generation == token, state.isActive else { return }
        switch tunnelState {
        case .failed, .stopped:
            end(.failed(state == .viewerOpened ? Self.tunnelLostMessage : Self.tunnelFailedMessage))
        case .idle, .starting, .processRunning:
            break
        }
    }

    private func end(_ next: RemoteDesktopHandoffState) {
        generation = nil
        pendingRetry?.cancel()
        pendingRetry = nil
        let cancel = cancelProbe
        cancelProbe = nil
        let previousTunnel = tunnel
        tunnel = nil
        previousTunnel?.onStateChange = nil
        cancel?()
        previousTunnel?.stop()
        transition(next)
    }

    private func transition(_ next: RemoteDesktopHandoffState) {
        state = next
        onStateChange?(next)
    }

    deinit {
        pendingRetry?.cancel()
        cancelProbe?()
        tunnel?.onStateChange = nil
        tunnel?.stop()
    }
}
