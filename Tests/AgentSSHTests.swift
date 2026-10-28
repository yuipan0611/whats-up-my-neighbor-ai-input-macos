import Foundation

private final class FakeSSHProcess: SSHProcessRunning {
    var onExit: ((Int32) -> Void)?
    var starts = 0, stops = 0
    var arguments: [String] = []
    var failStart = false
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    func start(arguments: [String]) throws {
        starts += 1; self.arguments = arguments
        if failStart { throw CocoaError(.executableNotLoadable) }
        onStart?()
    }
    func stop() { stops += 1; onStop?() }
}

@main
enum AgentSSHTests {
    static func main() throws {
        if CommandLine.arguments.contains("--arguments-json") {
            let args = try SSHTunnelConfiguration(hostAlias: "neighbor-test.invalid").arguments()
            print(String(data: try JSONEncoder().encode(args), encoding: .utf8)!)
            return
        }
        var scenarios = 0
        func check(_ name: String, _ test: () throws -> Void) rethrows { try test(); scenarios += 1 }
        let config = SSHTunnelConfiguration(hostAlias: "neighbor-vps")
        try check("arguments lock host verification, local bind and no commands") {
            let args = try config.arguments()
            for value in ["-N", "-T", "-n", "StrictHostKeyChecking=yes", "BatchMode=yes",
                          "ExitOnForwardFailure=yes", "ControlPath=none", "PermitLocalCommand=no",
                          "RemoteCommand=none", "ForwardAgent=no", "ForwardX11=no",
                          "ForkAfterAuthentication=no", "UpdateHostKeys=no"] { precondition(args.contains(value)) }
            precondition(args.contains("127.0.0.1:18421:127.0.0.1:8421"))
            precondition(Array(args.suffix(2)) == ["--", "neighbor-vps"])
            precondition(!args.contains("StrictHostKeyChecking=no") && !args.contains("-f"))
        }
        check("reject injected commands and invalid ports before process creation") {
            for alias in ["", "-oProxyCommand=bad", "vps;touch bad", "$(bad)", "user@host", "a b", "a\nb", ".bad", "伺服器"] {
                let c = SSHTunnelController(makeProcess: { preconditionFailure("must not create process") })
                do { try c.start(configuration: SSHTunnelConfiguration(hostAlias: alias)); preconditionFailure() }
                catch { precondition(c.state == .idle) }
            }
            for port in [0, 80, 65536, -1] {
                do { _ = try SSHTunnelConfiguration(hostAlias: "vps", localPort: port).arguments(); preconditionFailure() }
                catch {}
                do { _ = try SSHTunnelConfiguration(hostAlias: "vps", remotePort: port).arguments(); preconditionFailure() }
                catch {}
            }
        }
        try check("no launch on initialization; duplicate launch rejected") {
            let p = FakeSSHProcess(), c = SSHTunnelController(makeProcess: { p })
            precondition(c.state == .idle && p.starts == 0)
            try c.start(configuration: config)
            precondition(c.state == .processRunning && p.starts == 1)
            do { try c.start(configuration: config); preconditionFailure() }
            catch { precondition(p.starts == 1) }
            c.stop(); c.stop(); precondition(c.state == .stopped && p.stops == 1)
        }
        try check("start failure is explicit") {
            let p = FakeSSHProcess(), c = SSHTunnelController(makeProcess: { p }); p.failStart = true
            try c.start(configuration: config)
            guard case .failed = c.state else { preconditionFailure() }
        }
        try check("disconnect never retries or implies completed task") {
            for code: Int32 in [0, 1, 255] {
                let p = FakeSSHProcess(), c = SSHTunnelController(makeProcess: { p })
                try c.start(configuration: config); p.onExit?(code)
                guard case .failed = c.state else { preconditionFailure() }
                precondition(p.starts == 1)
            }
        }
        try check("late and synchronous stop callbacks cannot overwrite cancellation") {
            let p = FakeSSHProcess(), c = SSHTunnelController(makeProcess: { p })
            try c.start(configuration: config)
            let late = p.onExit!
            p.onStop = { late(255) }
            c.stop(); late(255)
            precondition(c.state == .stopped)
        }
        try check("late old process exit cannot overwrite replacement") {
            let first = FakeSSHProcess(), second = FakeSSHProcess()
            var queue = [first, second]
            let c = SSHTunnelController(makeProcess: { queue.removeFirst() })
            try c.start(configuration: config)
            let late = first.onExit!
            c.stop(); try c.start(configuration: config); late(255)
            precondition(c.state == .processRunning && second.starts == 1)
            c.stop()
        }
        try check("cancel while starting prevents process launch") {
            let p = FakeSSHProcess(), c = SSHTunnelController(makeProcess: { p })
            c.onStateChange = { if $0 == .starting { c.stop() } }
            try c.start(configuration: config)
            precondition(p.starts == 0 && c.state == .stopped)
        }
        try check("synchronous exit during start remains failed") {
            let p = FakeSSHProcess(), c = SSHTunnelController(makeProcess: { p })
            p.onStart = { p.onExit?(255) }
            try c.start(configuration: config)
            guard case .failed = c.state else { preconditionFailure() }
        }
        try check("controller release stops its owned process") {
            let p = FakeSSHProcess()
            var c: SSHTunnelController? = SSHTunnelController(makeProcess: { p })
            try c?.start(configuration: config)
            c = nil
            precondition(p.stops == 1)
        }
        try check("real system process exit callback, offline config parsing only") {
            let process = SystemSSHProcess()
            var exitCode: Int32?
            process.onExit = { exitCode = $0 }
            try process.start(arguments: ["-G", "-F", "/dev/null"] + config.arguments())
            let deadline = Date().addingTimeInterval(5)
            while exitCode == nil && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            precondition(exitCode == 0)
        }
        print("Agent SSH tests passed (\(scenarios) scenarios; no SSH connection)")
    }
}
