import Foundation
import Network

private final class FakeSSHProcess: SSHProcessRunning {
    var onExit: ((Int32) -> Void)?
    var starts = 0, stops = 0
    var arguments: [String] = []
    var failStart = false
    func start(arguments: [String]) throws {
        starts += 1; self.arguments = arguments
        if failStart { throw CocoaError(.executableNotLoadable) }
    }
    func stop() { stops += 1 }
}

private final class FakeProbe: VNCServerProbing {
    var ports: [Int] = []
    var timeouts: [TimeInterval] = []
    var completions: [(Bool) -> Void] = []
    var cancels = 0
    func probe(port: Int, timeout: TimeInterval, completion: @escaping (Bool) -> Void) -> () -> Void {
        ports.append(port); timeouts.append(timeout); completions.append(completion)
        return { [weak self] in self?.cancels += 1 }
    }
    func answerLast(_ reachable: Bool) { completions.last!(reachable) }
}

private final class FakeLauncher: RemoteViewerLaunching {
    var urls: [URL] = []
    var completions: [(Bool) -> Void] = []
    func open(_ url: URL, completion: @escaping (Bool) -> Void) { urls.append(url); completions.append(completion) }
}

private final class FakeTime {
    var current = Date(timeIntervalSince1970: 0)
    var queued: [(TimeInterval, DispatchWorkItem)] = []
    func runNext() {
        let (delay, item) = queued.removeFirst()
        current = current.addingTimeInterval(delay)
        if !item.isCancelled { item.perform() }
    }
}

private struct Harness {
    let process = FakeSSHProcess(), probe = FakeProbe(), launcher = FakeLauncher(), time = FakeTime()
    let controller: RemoteDesktopHandoffController
    init(allowTunnel: Bool = true, portFree: Bool = true) {
        let process = self.process, time = self.time
        controller = RemoteDesktopHandoffController(
            makeTunnel: {
                precondition(allowTunnel, "must not create an SSH tunnel")
                return SSHTunnelController(makeProcess: { process })
            },
            prober: probe, launcher: launcher,
            isLocalPortFree: { _ in portFree },
            schedule: { delay, item in time.queued.append((delay, item)) },
            now: { time.current })
    }
}

private final class LoopbackServer {
    let listener: NWListener
    private(set) var receivedBytes = 0
    private var connections: [NWConnection] = []
    init(greeting: Data?) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: .main)
            if let greeting { connection.send(content: greeting, completion: .contentProcessed { _ in }) }
            self.readContinuously(connection)
        }
        var ready = false
        listener.stateUpdateHandler = { if case .ready = $0 { ready = true } }
        listener.start(queue: .main)
        let deadline = Date().addingTimeInterval(5)
        while !ready && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(ready && port >= 1024, "loopback listener did not start")
    }
    private func readContinuously(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] data, _, isComplete, error in
            precondition(Thread.isMainThread)
            if let count = data?.count, count > 0 { self?.receivedBytes += count }
            if !isComplete && error == nil, let connection { self?.readContinuously(connection) }
        }
    }
    var port: Int { Int(listener.port?.rawValue ?? 0) }
    func close() { connections.forEach { $0.cancel() }; listener.cancel() }
}

private func realProbe(port: Int, timeout: TimeInterval = 1) -> (result: Bool, seconds: TimeInterval) {
    let started = Date()
    var result: Bool?
    _ = SystemVNCProbe().probe(port: port, timeout: timeout) { result = $0 }
    let deadline = Date().addingTimeInterval(timeout + 3)
    while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(result != nil, "probe never completed")
    return (result!, Date().timeIntervalSince(started))
}

@main
enum RemoteDesktopHandoffTests {
    static func main() throws {
        var scenarios = 0
        func check(_ name: String, _ test: () throws -> Void) rethrows { try test(); scenarios += 1 }
        let vps = RemoteDesktopTarget.linuxVPS(hostAlias: "neighbor-vps")

        check("viewer URLs are fixed loopback ports without credentials") {
            precondition(vps.viewerURL.absoluteString == "vnc://127.0.0.1:15901")
            precondition(RemoteDesktopTarget.macSecondUser.viewerURL.absoluteString == "vnc://127.0.0.1:5901")
            for allowed in ["vnc://127.0.0.1:15901", "vnc://127.0.0.1:5901"] {
                precondition(RemoteDesktopTarget.isAllowedViewerURL(URL(string: allowed)!))
            }
            for rejected in ["vnc://example.com:5901", "vnc://user:pw@127.0.0.1:15901", "vnc://127.0.0.1:22",
                             "vnc://127.0.0.1", "http://127.0.0.1:15901", "vnc://localhost:5901",
                             "vnc://127.0.0.1:15901/x", "vnc://127.0.0.1:15901?password=1"] {
                precondition(!RemoteDesktopTarget.isAllowedViewerURL(URL(string: rejected)!), rejected)
            }
        }
        check("RFB banner accepts only the 12-byte protocol version message") {
            for valid in ["RFB 003.008\n", "RFB 003.003\n", "RFB 004.001\n"] {
                precondition(RFBBanner.isValid(Data(valid.utf8)), valid)
            }
            for invalid in ["HTTP/1.1 200", "RFB 3.8\n", "RFB 003.008", "RFB 003.008\n\n", "rfb 003.008\n",
                            "RFB 003,008\n", "RFB 0a3.008\n", "SSH-2.0-Open", ""] {
                precondition(!RFBBanner.isValid(Data(invalid.utf8)), invalid)
            }
        }
        check("Screen Sharing launcher builds only the fixed argument array") {
            precondition(ScreenSharingLauncher.arguments(for: URL(string: "vnc://127.0.0.1:15901")!) ==
                ["-b", "com.apple.ScreenSharing", "vnc://127.0.0.1:15901"])
            precondition(ScreenSharingLauncher.arguments(for: URL(string: "vnc://example.com:5901")!) == nil)
            precondition(ScreenSharingLauncher.arguments(for: URL(string: "vnc://u:p@127.0.0.1:5901")!) == nil)
        }
        check("invalid aliases are rejected before any tunnel or process exists") {
            for alias in ["", "-oProxyCommand=bad", "vps;touch bad", "user@host", "a b", ".bad", "伺服器"] {
                let h = Harness(allowTunnel: false)
                do { try h.controller.start(.linuxVPS(hostAlias: alias)); preconditionFailure(alias) }
                catch { precondition(h.controller.state == .idle && h.probe.ports.isEmpty) }
            }
        }
        try check("VPS fails fast when 15901 is already in use") {
            let h = Harness(allowTunnel: false, portFree: false)
            try h.controller.start(vps)
            precondition(h.controller.state == .failed(RemoteDesktopHandoffController.portInUseMessage))
            precondition(h.probe.ports.isEmpty)
            precondition(h.launcher.urls.isEmpty)
        }
        try check("second user mode never checks the local port") {
            let probe = FakeProbe()
            let controller = RemoteDesktopHandoffController(
                prober: probe,
                isLocalPortFree: { _ in preconditionFailure("port check should not be called") })
            try controller.start(.macSecondUser)
            precondition(controller.state == .probing)
        }
        try check("VPS forwards 15901 to remote 5901 and opens the viewer only after a banner") {
            let h = Harness()
            try h.controller.start(vps)
            precondition(h.process.arguments.contains("127.0.0.1:15901:127.0.0.1:5901"))
            precondition(Array(h.process.arguments.suffix(2)) == ["--", "neighbor-vps"])
            precondition(h.controller.state == .probing && h.probe.ports == [15901] && h.launcher.urls.isEmpty)
            h.probe.answerLast(true)
            precondition(h.controller.state == .openingViewer)
            precondition(h.launcher.urls == [URL(string: "vnc://127.0.0.1:15901")!])
            h.launcher.completions[0](true)
            precondition(h.controller.state == .viewerOpened && h.process.stops == 0)
            h.controller.stop()
            precondition(h.controller.state == .stopped && h.process.stops == 1)
        }
        try check("probe retries every 0.5 s, then fails at 10 s without a viewer and stops the tunnel") {
            let h = Harness()
            try h.controller.start(vps)
            while h.controller.state == .probing {
                h.probe.answerLast(false)
                if h.controller.state == .probing { h.time.runNext() }
            }
            precondition(h.controller.state == .failed(RemoteDesktopHandoffController.probeTimeoutMessage(for: vps)))
            precondition(h.probe.ports.count == 20 && h.launcher.urls.isEmpty && h.process.stops == 1)
            precondition(h.time.queued.isEmpty)
        }
        try check("no probe attempt may run past the 10 s deadline") {
            let h = Harness()
            try h.controller.start(vps)
            while h.controller.state == .probing {
                h.probe.answerLast(false)
                if h.controller.state == .probing { h.time.runNext() }
            }
            precondition(h.probe.timeouts.count == 20)
            precondition(h.probe.timeouts.allSatisfy { $0 <= 2 })
            precondition(Array(h.probe.timeouts.suffix(3)) == [1.5, 1.0, 0.5])
        }
        try check("SSH exit while probing fails; the late probe success is ignored") {
            let h = Harness()
            try h.controller.start(vps)
            h.process.onExit?(255)
            precondition(h.controller.state == .failed(RemoteDesktopHandoffController.tunnelFailedMessage))
            precondition(h.probe.cancels == 1)
            h.probe.answerLast(true)
            precondition(h.launcher.urls.isEmpty)
        }
        try check("stale SSH exit from a previous VPS run cannot end the next run") {
            let first = FakeSSHProcess(), second = FakeSSHProcess()
            var processes = [first, second]
            let probe = FakeProbe(), launcher = FakeLauncher(), time = FakeTime()
            let controller = RemoteDesktopHandoffController(
                makeTunnel: { SSHTunnelController(makeProcess: { processes.removeFirst() }) },
                prober: probe, launcher: launcher,
                isLocalPortFree: { _ in true },
                schedule: { delay, item in time.queued.append((delay, item)) },
                now: { time.current })
            try controller.start(vps)
            let late = first.onExit!
            controller.stop()
            try controller.start(vps)
            late(255)
            precondition(controller.state == .probing)
            precondition(second.starts == 1)
        }
        try check("stop while probing cancels the attempt and pending retry") {
            let h = Harness()
            try h.controller.start(vps)
            h.probe.answerLast(false)
            precondition(h.time.queued.count == 1)
            h.controller.stop()
            precondition(h.controller.state == .stopped && h.process.stops == 1)
            h.time.runNext()
            h.probe.answerLast(true)
            precondition(h.probe.ports.count == 1 && h.launcher.urls.isEmpty && h.controller.state == .stopped)
        }
        try check("duplicate start is rejected while active") {
            let h = Harness()
            try h.controller.start(vps)
            do { try h.controller.start(vps); preconditionFailure() }
            catch { precondition(error is RemoteDesktopHandoffError && h.process.starts == 1) }
            do { try h.controller.start(.macSecondUser); preconditionFailure() }
            catch { precondition(h.probe.ports == [15901]) }
        }
        try check("second user mode probes 5901 directly and never creates SSH") {
            let h = Harness(allowTunnel: false)
            try h.controller.start(.macSecondUser)
            precondition(h.controller.state == .probing && h.probe.ports == [5901])
            h.probe.answerLast(true)
            precondition(h.launcher.urls == [URL(string: "vnc://127.0.0.1:5901")!])
            h.launcher.completions[0](true)
            precondition(h.controller.state == .viewerOpened && h.process.starts == 0)
            h.controller.stop()
            precondition(h.controller.state == .stopped)
        }
        try check("viewer launch failure stops the tunnel") {
            let h = Harness()
            try h.controller.start(vps)
            h.probe.answerLast(true); h.launcher.completions[0](false)
            precondition(h.controller.state == .failed(RemoteDesktopHandoffController.viewerFailedMessage))
            precondition(h.process.stops == 1)
        }
        try check("tunnel loss after the viewer opened is reported, never retried") {
            let h = Harness()
            try h.controller.start(vps)
            h.probe.answerLast(true); h.launcher.completions[0](true)
            h.process.onExit?(0)
            precondition(h.controller.state == .failed(RemoteDesktopHandoffController.tunnelLostMessage))
            precondition(h.process.starts == 1 && h.probe.ports.count == 1)
        }
        try check("SSH launch failure surfaces without probing") {
            let h = Harness(); h.process.failStart = true
            try h.controller.start(vps)
            precondition(h.controller.state == .failed(RemoteDesktopHandoffController.tunnelFailedMessage))
            precondition(h.probe.ports.isEmpty && h.launcher.urls.isEmpty)
        }
        try check("a new handoff ignores callbacks from the previous one") {
            let h = Harness(allowTunnel: false)
            try h.controller.start(.macSecondUser)
            let staleProbe = h.probe.completions[0]
            h.controller.stop()
            try h.controller.start(.macSecondUser)
            staleProbe(true)
            precondition(h.controller.state == .probing && h.launcher.urls.isEmpty)
            h.probe.answerLast(true)
            let staleLaunch = h.launcher.completions[0]
            h.controller.stop()
            try h.controller.start(.macSecondUser)
            staleLaunch(true)
            precondition(h.controller.state == .probing)
        }
        try check("releasing the controller stops its owned tunnel") {
            let process = FakeSSHProcess(), probe = FakeProbe()
            var controller: RemoteDesktopHandoffController? = RemoteDesktopHandoffController(
                makeTunnel: { SSHTunnelController(makeProcess: { process }) },
                prober: probe, launcher: FakeLauncher(),
                isLocalPortFree: { _ in true },
                schedule: { _, _ in }, now: Date.init)
            try controller?.start(vps)
            controller = nil
            precondition(process.stops == 1 && probe.cancels == 1)
        }
        try check("real probe: loopback server with an RFB banner is accepted") {
            let server = try LoopbackServer(greeting: Data("RFB 003.008\n".utf8))
            defer { server.close() }
            precondition(realProbe(port: server.port).result == true)
        }
        try check("real probe: a non-VNC server is rejected") {
            let server = try LoopbackServer(greeting: Data("HTTP/1.1 200 OK\r\n\r\n".utf8))
            defer { server.close() }
            precondition(realProbe(port: server.port).result == false)
        }
        try check("real probe: a silent server times out") {
            let server = try LoopbackServer(greeting: nil)
            defer { server.close() }
            let outcome = realProbe(port: server.port, timeout: 0.5)
            precondition(outcome.result == false && outcome.seconds < 2)
        }
        try check("real probe: a closed port fails within the timeout") {
            let server = try LoopbackServer(greeting: nil)
            let port = server.port
            server.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let outcome = realProbe(port: port, timeout: 5)
            precondition(outcome.result == false && outcome.seconds < 0.5)
        }
        try check("real probe sends nothing to the server") {
            let server = try LoopbackServer(greeting: Data("RFB 003.008\n".utf8))
            defer { server.close() }
            let outcome = realProbe(port: server.port)
            precondition(outcome.result == true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            precondition(server.receivedBytes == 0)
        }
        try check("real probe: cancel after completion never calls back again") {
            let server = try LoopbackServer(greeting: Data("RFB 003.008\n".utf8))
            defer { server.close() }
            var callbacks = 0
            let cancel = SystemVNCProbe().probe(port: server.port, timeout: 1) { _ in callbacks += 1 }
            let deadline = Date().addingTimeInterval(2)
            while callbacks == 0 && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(callbacks == 1)
            cancel()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            precondition(callbacks == 1)
        }
        try check("real port check reports a held port as busy and a released one as free") {
            let server = try LoopbackServer(greeting: nil)
            let port = server.port
            precondition(!SystemLocalPort.isFree(port: port))
            server.close()
            let deadline = Date().addingTimeInterval(2)
            var freed = false
            while !freed && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                freed = SystemLocalPort.isFree(port: port)
            }
            precondition(freed)
        }
        try check("real port check: a port left in TIME_WAIT without a listener counts as free") {
            let server = try LoopbackServer(greeting: nil)
            let port = server.port
            let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
            client.start(queue: .main)
            let deadline = Date().addingTimeInterval(2)
            while client.state != .ready && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(client.state == .ready)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            server.close()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            client.cancel()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            precondition(SystemLocalPort.isFree(port: port) == true)
        }
        check("panel: start needs an alias for VPS only and is disabled while active") {
            let h = Harness(), model = RemoteDesktopHandoffModel(controller: h.controller)
            precondition(!model.canStart)
            model.hostAlias = "   "; precondition(!model.canStart)
            model.targetKind = .macSecondUser; precondition(model.canStart)
            model.targetKind = .linuxVPS; model.hostAlias = "neighbor-vps"; precondition(model.canStart)
            model.start()
            precondition(model.isActive && model.isWorking && !model.canStart)
            precondition(model.statusText == "正在確認 VNC 伺服器…")
        }
        check("panel: an invalid alias shows the SSH error and starts nothing") {
            let h = Harness(allowTunnel: false), model = RemoteDesktopHandoffModel(controller: h.controller)
            model.hostAlias = "vps;touch bad"
            model.start()
            precondition(model.state == .idle && h.probe.ports.isEmpty)
            precondition(model.failureMessage == SSHTunnelError.invalidAlias.errorDescription)
        }
        check("panel: stop is disabled while the viewer is launching") {
            let h = Harness(allowTunnel: false), model = RemoteDesktopHandoffModel(controller: h.controller)
            model.targetKind = .macSecondUser
            model.start()
            precondition(model.state == .probing && model.canStop)
            h.probe.answerLast(true)
            precondition(model.state == .openingViewer && !model.canStop)
            h.launcher.completions[0](true)
            precondition(model.state == .viewerOpened && model.canStop)
        }
        check("panel: an invalid alias after a stop shows only the error") {
            let h = Harness(allowTunnel: false), model = RemoteDesktopHandoffModel(controller: h.controller)
            model.targetKind = .macSecondUser
            model.start()
            h.probe.answerLast(true)
            h.launcher.completions[0](true)
            model.stop()
            precondition(model.state == .stopped)
            model.targetKind = .linuxVPS
            model.hostAlias = "bad alias"
            model.start()
            precondition(model.statusText == nil)
            precondition(model.failureMessage == SSHTunnelError.invalidAlias.errorDescription)
        }
        check("panel: alias is trimmed and only kept in memory") {
            let h = Harness(), model = RemoteDesktopHandoffModel(controller: h.controller)
            model.hostAlias = "  neighbor-vps\n"
            model.start()
            precondition(Array(h.process.arguments.suffix(2)) == ["--", "neighbor-vps"])
            precondition(model.hostAlias == "  neighbor-vps\n")
        }
        check("panel: status follows the controller through open, stop and failure") {
            let h = Harness(), model = RemoteDesktopHandoffModel(controller: h.controller)
            model.hostAlias = "neighbor-vps"
            model.start(); h.probe.answerLast(true)
            precondition(model.statusText == "正在開啟螢幕共享…")
            h.launcher.completions[0](true)
            precondition(model.state == .viewerOpened && !model.isWorking)
            precondition(model.statusText!.contains("本 App 不保存密碼"))
            model.stop()
            precondition(model.statusText == "已結束接手，SSH 通道已關閉。" && model.failureMessage == nil)
            model.targetKind = .macSecondUser
            model.start(); h.probe.answerLast(false)
            while model.isActive { h.time.runNext(); h.probe.answerLast(false) }
            precondition(model.statusText == nil)
            precondition(model.failureMessage == RemoteDesktopHandoffController.probeTimeoutMessage(for: .macSecondUser))
            model.start(); h.probe.answerLast(true); h.launcher.completions.last!(true); model.stop()
            precondition(model.statusText == "已結束接手。螢幕共享視窗若仍開著，請自行關閉。")
        }
        print("Remote desktop handoff tests passed (\(scenarios) scenarios; loopback only, no SSH or viewer launched)")
    }
}
