import Foundation

final class ConfiguredSSHProcess: SSHProcessRunning {
    private let inner = SystemSSHProcess()
    private let configPath: String

    init(configPath: String) {
        self.configPath = configPath
    }

    var onExit: ((Int32) -> Void)? {
        get { inner.onExit }
        set { inner.onExit = newValue }
    }

    func start(arguments: [String]) throws {
        try inner.start(arguments: ["-F", configPath] + arguments)
    }

    func stop() {
        inner.stop()
    }
}

@main
enum RemoteDesktopVPSLiveCheck {
    static func main() {
        var sshConfigPath: String?
        var holdSeconds = 20
        var hostAlias = "127.0.0.1"

        var index = 1
        while index < CommandLine.arguments.count {
            let arg = CommandLine.arguments[index]
            if arg == "--ssh-config", index + 1 < CommandLine.arguments.count {
                sshConfigPath = CommandLine.arguments[index + 1]
                index += 2
            } else if arg == "--alias", index + 1 < CommandLine.arguments.count {
                hostAlias = CommandLine.arguments[index + 1]
                index += 2
            } else if arg == "--hold", index + 1 < CommandLine.arguments.count {
                if let val = Int(CommandLine.arguments[index + 1]) {
                    holdSeconds = val
                }
                index += 2
            } else {
                index += 1
            }
        }

        guard let configPath = sshConfigPath else {
            fputs("Missing required argument --ssh-config <path>\n", stderr)
            exit(1)
        }

        let controller = RemoteDesktopHandoffController(makeTunnel: {
            SSHTunnelController(makeProcess: { ConfiguredSSHProcess(configPath: configPath) })
        })

        controller.onStateChange = { state in
            print("state: \(state)")
        }

        do {
            try controller.start(.linuxVPS(hostAlias: hostAlias))
        } catch {
            print("start failed: \(error)")
            print("final state: \(controller.state)")
            exit(1)
        }

        let start = Date()
        let timeout: TimeInterval = 25.0

        while controller.state.isActive && controller.state != .viewerOpened && Date().timeIntervalSince(start) < timeout {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        guard controller.state == .viewerOpened else {
            print("final state: \(controller.state)")
            exit(1)
        }

        print("viewer opened; holding tunnel for \(holdSeconds) s")

        let holdStart = Date()
        let holdTimeout = TimeInterval(holdSeconds)
        var holdFailed = false

        while Date().timeIntervalSince(holdStart) < holdTimeout {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            if case .failed = controller.state {
                holdFailed = true
                break
            }
        }

        if holdFailed {
            print("state: \(controller.state)")
            print("final state: \(controller.state)")
            exit(3)
        }

        controller.stop()

        let stopStart = Date()
        var isPortFree = false
        while Date().timeIntervalSince(stopStart) < 5.0 {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            if SystemLocalPort.isFree(port: 15901) {
                isPortFree = true
                break
            }
        }

        print("tunnel closed after stop: \(isPortFree)")
        print("final state: \(controller.state)")

        if isPortFree {
            exit(0)
        } else {
            exit(4)
        }
    }
}
