import Foundation

/// Runs the signed cleanup resource after ordinary launch or Sparkle relaunch.
/// Work stays off the main queue and never presents UI or touches preferences.
enum OldAppBackupCleanup {
    static func schedule() {
        guard Bundle.main.bundleIdentifier == "tw.panh.FreeVoiceType" else { return }
        attempt(appURL: Bundle.main.bundleURL, remainingRetries: 3)
    }

    private static func attempt(appURL: URL, remainingRetries: Int) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            let status = run(appURL: appURL)
            if status == 75, remainingRetries > 0 {
                attempt(appURL: appURL, remainingRetries: remainingRetries - 1)
            } else {
                UpdateDiagnostics.shared.record(.oldBackupCleanup, succeeded: status == 0)
            }
        }
    }

    // Synchronous entry point for a disposable-profile integration probe.
    static func run(appURL: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [appURL.appendingPathComponent("Contents/Resources/OldAppCleanup.zsh").path,
                             "--app-launch", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch { return 70 }
    }
}
