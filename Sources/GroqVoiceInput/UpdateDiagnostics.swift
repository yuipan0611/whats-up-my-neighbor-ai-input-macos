import Foundation

/// Opt-in, bounded local verification. No API key, transcript, clipboard,
/// vocabulary, application titles or preference values fit this schema.
final class UpdateDiagnostics {
    enum Event: String, Codable {
        case launch, apiKeyAccess, microphoneAuthorized, accessibilityAllowed
        case recordingHotKey, clipboardHotKey, clipboardPasteGesture, updaterStarted, updateDetected
        case notificationPermission, notificationQueued, manualCheck, sessionFinished
        case relaunchDeferred, relaunchStarted, oldBackupCleanup
    }
    struct Entry: Codable {
        let time: TimeInterval
        let event: Event
        let version: String?
        let succeeded: Bool?
        let authorization: Int?
    }
    static let shared = UpdateDiagnostics(url: ProcessInfo.processInfo.environment["NEIGHBOR_UPDATE_DIAGNOSTICS_PATH"].map { URL(fileURLWithPath: $0) })
    private let url: URL?
    private let lock = NSLock()

    init(url: URL?) { self.url = url }

    func record(_ event: Event, version: String? = nil, succeeded: Bool? = nil, authorization: Int? = nil) {
        guard let url else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            var entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))) ?? []
            entries.append(Entry(time: Date().timeIntervalSince1970, event: event, version: version,
                                 succeeded: succeeded, authorization: authorization))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Array(entries.suffix(128))).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* Verification must never affect normal dictation or updates. */ }
    }
}
