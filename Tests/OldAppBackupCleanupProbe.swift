import Foundation
import Darwin

@main
struct OldAppBackupCleanupProbe {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(64) }
        exit(OldAppBackupCleanup.run(appURL: URL(fileURLWithPath: CommandLine.arguments[1])))
    }
}
