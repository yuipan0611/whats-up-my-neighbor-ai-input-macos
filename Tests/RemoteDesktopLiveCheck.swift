import Foundation

@main
enum RemoteDesktopLiveCheck {
    static func main() {
        let controller = RemoteDesktopHandoffController()

        controller.onStateChange = { state in
            print("[RemoteDesktopLiveCheck] state: \(state)")
        }

        do {
            try controller.start(.macSecondUser)
        } catch {
            print("[RemoteDesktopLiveCheck] start failed: \(error)")
            exit(1)
        }

        let start = Date()
        let timeout: TimeInterval = 20.0

        while controller.state != .viewerOpened && controller.state.isActive && Date().timeIntervalSince(start) < timeout {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        let finalState = controller.state
        print("[RemoteDesktopLiveCheck] final state: \(finalState)")

        if finalState == .viewerOpened {
            exit(0)
        } else {
            exit(1)
        }
    }
}
