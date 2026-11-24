import Foundation
import Darwin

/// Explicitly enabled, bounded local diagnostics. Its typed schema cannot accept
/// transcript text, clipboard data, app names, window titles, PIDs or credentials.
final class PasteDiagnostics {
    static let environmentKey = "NEIGHBOR_PASTE_DIAGNOSTICS_PATH"
    static let shared = PasteDiagnostics(environment: ProcessInfo.processInfo.environment)

    enum Tag: String, Codable {
        case startup = "startup", toggle = "toggle", stateChange = "state"
        case recordingStop = "recording.stop"
        case capture = "capture"
        case captureResult = "capture.result"
        case snapshotFrontmost = "snapshot.frontmost"
        case focusSystemQuery = "focus.system.query"
        case focusApplicationQuery = "focus.application.query"
        case snapshotIdentity = "snapshot.identity"
        case snapshotCapabilities = "snapshot.capabilities"
        case validation = "validation"
        case validationResult = "validation.result"
        case insertion = "insertion"
        case insertionResult = "insertion.result"
        case postPreparation = "post.preparation"
        case postCreation = "post.creation"
        case postCompleted = "post.completed"
        case learningStart = "learning.start", learningStopped = "learning.stopped"
        case learningEdit = "learning.edit", learningReview = "learning.review", learningToast = "learning.toast"
        case learningTarget = "learning.target"
        case vocabularyPreviewRequest = "vocabulary.preview.request"
    }

    enum StopMethod: String, Codable { case shortcut, hudButton, menu }

    enum Failure: String, Codable {
        case accessibilityDenied, noEditableTarget, targetChanged, targetExpired
        case noTarget, eventUnavailable, copyFailed
    }

    enum Role: String, Codable {
        case textField = "AXTextField", textArea = "AXTextArea", comboBox = "AXComboBox"
        case secureTextField = "AXSecureTextField", staticText = "AXStaticText"
        case group = "AXGroup", webArea = "AXWebArea", button = "AXButton"
        case window = "AXWindow", menu = "AXMenu", application = "AXApplication"
        case missing, other

        init(attribute: String?) {
            guard let attribute, !attribute.isEmpty else { self = .missing; return }
            self = Role(rawValue: attribute) ?? .other
        }
    }

    enum Subrole: String, Codable {
        case secureTextField = "AXSecureTextField", searchField = "AXSearchField"
        case standardWindow = "AXStandardWindow", missing, other

        init(attribute: String?) {
            guard let attribute, !attribute.isEmpty else { self = .missing; return }
            self = Subrole(rawValue: attribute) ?? .other
        }
    }

    enum State: String, Codable {
        case idle, starting, recording, finalizing, transcribing, awaitingRetry, delivering
    }

    enum LearningStage: String, Codable {
        case begin, target, selection, range, boundaries, observing, editing, review, toast, presenting, completed
    }

    enum LearningReason: String, Codable {
        case targetUnavailable, selectionUnavailable, characterCountUnavailable
        case rangeUnavailable, rangeMismatch, boundaryMismatch, targetChanged
        case selectionCrossesBoundary, invalidRange, contextChanged, noCandidate
        case candidateUnavailable, cancelled, expired, selectionPending, presentationUnavailable
        case characterCountMismatch, selectionOutsideRange
    }

    enum RangeReadMethod: String, Codable { case plain, attributed }

    struct Event: Codable {
        let tag: Tag
        var stopMethod: StopMethod? = nil
        var trusted: Bool? = nil
        var localPolicy: Bool? = nil
        var canStart: Bool? = nil
        var recordingBusy: Bool? = nil
        var state: State? = nil
        var frontmostAvailable: Bool? = nil
        var frontmostIsSelf: Bool? = nil
        var focusedElementAvailable: Bool? = nil
        var queryResult: Int32? = nil
        var elementOwnerMatches: Bool? = nil
        var frontmostUnchanged: Bool? = nil
        var role: Role? = nil
        var subrole: Subrole? = nil
        var canSetValue: Bool? = nil
        var localEligible: Bool? = nil
        var strictEligible: Bool? = nil
        var enabled: Bool? = nil
        var readOnly: Bool? = nil
        var explicitlyEditable: Bool? = nil
        var protectedContent: Bool? = nil
        var hasWindow: Bool? = nil
        var hasTarget: Bool? = nil
        var hasCurrent: Bool? = nil
        var processMatches: Bool? = nil
        var bundleMatches: Bool? = nil
        var elementMatches: Bool? = nil
        var windowMatches: Bool? = nil
        var windowTitleMatches: Bool? = nil
        var expired: Bool? = nil
        var accepted: Bool? = nil
        var failure: Failure? = nil
        var captureFailure: Failure? = nil
        var copySucceeded: Bool? = nil
        var postEventReturned: Bool? = nil
        var postEventPermission: Bool? = nil
        var modifierFlags: UInt64? = nil
        var secureEventInputEnabled: Bool? = nil
        var eventSourceCreated: Bool? = nil
        var keyDownCreated: Bool? = nil
        var keyUpCreated: Bool? = nil
        var learningStage: LearningStage? = nil
        var learningReason: LearningReason? = nil
        var selectionAvailable: Bool? = nil
        var selectionCollapsed: Bool? = nil
        var characterCountAvailable: Bool? = nil
        var rangeReadable: Bool? = nil
        var rangeReadMethod: RangeReadMethod? = nil
        var rangeMatches: Bool? = nil
        var boundariesMatch: Bool? = nil
        var candidateFound: Bool? = nil
        var contextValid: Bool? = nil
        var added: Bool? = nil
        var panelVisible: Bool? = nil
        var panelOnActiveSpace: Bool? = nil
        var panelOcclusionVisible: Bool? = nil
        var panelIntersectsScreen: Bool? = nil
        var appHidden: Bool? = nil
        var focusUnchanged: Bool? = nil
        var isPreview: Bool? = nil
    }

    private struct Report: Codable {
        var schemaVersion = 2
        let events: [Event]
        let lastFailure: [Event]?
    }

    private let outputURL: URL?
    private let lock = NSLock()
    private var events: [Event] = []
    private var lastFailure: [Event]?
    var isEnabled: Bool { outputURL != nil }

    init(environment: [String: String]) {
        if let path = environment[Self.environmentKey], path.hasPrefix("/"), !path.hasSuffix("/") {
            let url = URL(fileURLWithPath: path)
            outputURL = url
            // Restore only this typed, bounded failure snapshot, never arbitrary log contents.
            if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber,
               size.intValue <= 65_536,
               let data = try? Data(contentsOf: url),
               let report = try? JSONDecoder().decode(Report.self, from: data),
               report.schemaVersion == 2, let failure = report.lastFailure,
               failure.last?.tag == .insertionResult, failure.last?.failure != nil {
                lastFailure = Array(failure.suffix(40))
            }
        } else {
            outputURL = nil
        }
    }

    func record(_ event: Event, beginCapture: Bool = false) {
        guard let outputURL else { return }
        lock.lock()
        defer { lock.unlock() }
        if beginCapture { events.removeAll(keepingCapacity: true) }
        events.append(event)
        if events.count > 40 { events.removeFirst(events.count - 40) }
        if event.tag == .insertionResult, event.failure != nil {
            lastFailure = events
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Report(events: events, lastFailure: lastFailure)) else { return }
        // Create with private permissions before writing; rename atomically so a
        // reader never observes a partial report. No parent directories are created.
        let temporary = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".neighbor-paste-\(UUID().uuidString).json")
        let manager = FileManager.default
        guard manager.createFile(atPath: temporary.path, contents: data,
                                 attributes: [.posixPermissions: 0o600]) else { return }
        if Darwin.rename(temporary.path, outputURL.path) != 0 {
            try? manager.removeItem(at: temporary)
        }
    }
}
