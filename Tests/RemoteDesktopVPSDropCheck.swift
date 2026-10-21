import Foundation
import Network
import Darwin

final class RecordingLauncher: RemoteViewerLaunching {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL, completion: @escaping (Bool) -> Void) {
        openedURLs.append(url)
        DispatchQueue.main.async {
            completion(true)
        }
    }
}

@main
enum RemoteDesktopVPSDropCheck {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var hostAlias = "neighbor-vps"
        var holdSeconds = 600
        var dropTimeout = 120
        var readyFilePath: String?

        var index = 1
        while index < CommandLine.arguments.count {
            let arg = CommandLine.arguments[index]
            if arg == "--alias", index + 1 < CommandLine.arguments.count {
                hostAlias = CommandLine.arguments[index + 1]
                index += 2
            } else if arg == "--hold-seconds", index + 1 < CommandLine.arguments.count {
                if let val = Int(CommandLine.arguments[index + 1]) {
                    holdSeconds = val
                }
                index += 2
            } else if arg == "--drop-timeout", index + 1 < CommandLine.arguments.count {
                if let val = Int(CommandLine.arguments[index + 1]) {
                    dropTimeout = val
                }
                index += 2
            } else if arg == "--ready-file", index + 1 < CommandLine.arguments.count {
                readyFilePath = CommandLine.arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }

        guard let readyFilePath = readyFilePath else {
            fputs("Missing required argument --ready-file <path>\n", stderr)
            exit(1)
        }

        let launcher = RecordingLauncher()
        let controller = RemoteDesktopHandoffController(launcher: launcher)

        let startTime = Date()
        controller.onStateChange = { state in
            let elapsed = Date().timeIntervalSince(startTime)
            print(String(format: "[t=%.1fs] state: %@", elapsed, String(describing: state)))
        }

        var signalSources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                print("signal received; stopping tunnel")
                controller.stop()
                exit(130)
            }
            source.resume()
            signalSources.append(source)
        }

        do {
            try controller.start(.linuxVPS(hostAlias: hostAlias))
        } catch {
            print("start failed: \(error)")
            print("final state: \(controller.state)")
            exit(1)
        }

        let startWait = Date()
        while controller.state.isActive && controller.state != .viewerOpened && Date().timeIntervalSince(startWait) < 30.0 {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        guard controller.state == .viewerOpened else {
            print("final state: \(controller.state)")
            exit(1)
        }

        let holdStart = Date()
        var lastCheck = holdStart
        while Date().timeIntervalSince(holdStart) < TimeInterval(holdSeconds) {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            if Date().timeIntervalSince(lastCheck) >= 10.0 {
                lastCheck = Date()
                let elapsed = Date().timeIntervalSince(startTime)
                let stateOk = (controller.state == .viewerOpened)
                let listenerOk = !SystemLocalPort.isFree(port: 15901)
                var probeOk = false
                var probeFinished = false
                let cancelProbe = SystemVNCProbe().probe(port: 15901, timeout: 3.0) { ok in
                    probeOk = ok
                    probeFinished = true
                }
                let probeWaitStart = Date()
                while !probeFinished && Date().timeIntervalSince(probeWaitStart) < 3.5 {
                    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
                }
                if !probeFinished {
                    cancelProbe()
                }
                print(String(format: "alive t=%.1fs state=%@ listener=%@ probe=%@", elapsed, String(describing: controller.state), String(listenerOk), String(probeOk)))
                if !stateOk || !listenerOk || !probeOk {
                    print(String(format: "hold failed at t=%.1fs", elapsed))
                    print("final state: \(controller.state)")
                    exit(3)
                }
            }
        }

        print("HOLD_DONE")
        let holdDoneTime = Date()
        FileManager.default.createFile(atPath: readyFilePath, contents: nil)

        let dropWaitStart = Date()
        var failedMessage: String?
        while Date().timeIntervalSince(dropWaitStart) < TimeInterval(dropTimeout) {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            if case .failed(let msg) = controller.state {
                failedMessage = msg
                break
            }
        }

        guard let message = failedMessage else {
            print("final state: \(controller.state)")
            exit(4)
        }

        let afterSeconds = String(format: "%.1f", Date().timeIntervalSince(holdDoneTime))
        print("DROP_DETECTED after=\(afterSeconds)s message=\(message)")

        let releaseStart = Date()
        var isReleased = false
        while Date().timeIntervalSince(releaseStart) < 5.0 {
            if SystemLocalPort.isFree(port: 15901) {
                isReleased = true
                break
            }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        print("tunnel released: \(isReleased)")
        print("final state: \(controller.state)")

        _ = signalSources
        if message == RemoteDesktopHandoffController.tunnelLostMessage && isReleased {
            exit(0)
        } else {
            exit(5)
        }
    }
}
